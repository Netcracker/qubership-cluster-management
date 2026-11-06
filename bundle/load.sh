#!/usr/bin/env bash
# Uploads a bundle built by bundle/build.sh into Nexus; safe to re-run (existing files are skipped).
# Creates, if missing: raw repository "bundle" (files/, apt/, charts/) and docker repository "images" on port 8082,
# both readable anonymously. Paths and ports are what components/terraform/kubemarine expects.
#   NEXUS_URL             http://<address>:8081 (reached directly or through HTTP(S)_PROXY / ALL_PROXY)
#   NEXUS_ADMIN_PASSWORD  admin password; on first run it replaces admin123 (set by bundle/nexus-install.sh)
#   BUNDLE_DIR            bundle directory (default .local-runtime/bundle)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${NEXUS_URL:?}" "${NEXUS_ADMIN_PASSWORD:?Run through local/lab.sh with-secrets <stack>}"
bundle=${BUNDLE_DIR:-$PWD/.local-runtime/bundle}
registry="${NEXUS_URL#*://}" registry="${registry%:*}:8082"
[[ -f $bundle/manifest.yaml ]] || { echo "No bundle in $bundle; run bundle/build.sh" >&2; exit 1; }

api() { curl -fsS -u "admin:$NEXUS_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }

echo "Waiting for $NEXUS_URL"
for _ in $(seq 120); do curl -fsS -o /dev/null "$NEXUS_URL/service/rest/v1/status/writable" && break; sleep 5; done
curl -fsS -o /dev/null "$NEXUS_URL/service/rest/v1/status/writable"

if curl -fsS -o /dev/null -u admin:admin123 "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null; then
    echo 'Setting the admin password'
    curl -fsS -u admin:admin123 -X PUT -H 'Content-Type: text/plain' --data-raw "$NEXUS_ADMIN_PASSWORD" \
        "$NEXUS_URL/service/rest/v1/security/users/admin/change-password"
fi

# Community Edition refuses uploads until its EULA is accepted: running this script accepts it
# (https://links.sonatype.com/products/nxrm/ce-eula).
eula=$(api "$NEXUS_URL/service/rest/v1/system/eula" 2>/dev/null || true)
if [[ $(jq -r '.accepted' <<<"${eula:-null}") == false ]]; then
    api -X POST "$NEXUS_URL/service/rest/v1/system/eula" -d "$(jq -c '.accepted = true' <<<"$eula")"
fi

api -X PUT "$NEXUS_URL/service/rest/v1/security/realms/active" -d '["NexusAuthenticatingRealm","DockerToken"]'
api -X PUT "$NEXUS_URL/service/rest/v1/security/anonymous" \
    -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' >/dev/null

storage='{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"allow"}'
api -o /dev/null "$NEXUS_URL/service/rest/v1/repositories/bundle" 2>/dev/null ||
    api -X POST "$NEXUS_URL/service/rest/v1/repositories/raw/hosted" \
        -d "{\"name\":\"bundle\",\"online\":true,\"storage\":$storage,\"raw\":{\"contentDisposition\":\"inline\"}}"
api -o /dev/null "$NEXUS_URL/service/rest/v1/repositories/images" 2>/dev/null ||
    api -X POST "$NEXUS_URL/service/rest/v1/repositories/docker/hosted" \
        -d "{\"name\":\"images\",\"online\":true,\"storage\":$storage,\"docker\":{\"v1Enabled\":false,\"forceBasicAuth\":false,\"httpPort\":8082}}"

echo 'Uploading files, apt packages and charts'
(cd "$bundle" && find files apt charts -type f) | while read -r path; do
    url="$NEXUS_URL/repository/bundle/$path"
    # index files change when the bundle changes; everything else is versioned by its name
    if [[ $path == apt/Packages || $path == charts/index.yaml ]] || ! curl -fsS -o /dev/null -I "$url" 2>/dev/null; then
        api -o /dev/null --upload-file "$bundle/$path" "$url"
    fi
done

echo "Pushing images to $registry"
export DOCKER_CONFIG; DOCKER_CONFIG=$(mktemp -d); trap 'rm -rf "$DOCKER_CONFIG"' EXIT
crane auth login "$registry" -u admin -p "$NEXUS_ADMIN_PASSWORD" --insecure 2>/dev/null
yq -r '(.images | keys[]), .app_images[]' "$bundle/manifest.yaml" | while read -r target; do
    crane manifest --insecure "$registry/$target" >/dev/null 2>&1 ||
        crane push --insecure "$bundle/images/$(tr '/:' '__' <<<"$target").tar" "$registry/$target"
done
echo "Nexus loaded: $NEXUS_URL/#browse/browse"
