#!/usr/bin/env bash
# Downloads everything listed in bundle/manifest.yaml into one directory that bundle/load.sh uploads into Nexus.
# Needs Internet, docker, curl, helm, crane and yq (all in the tools image). Re-running skips what is already there.
#   BUNDLE_DIR       output directory (default .local-runtime/bundle)
#   BUNDLE_MANIFEST  manifest to read (default bundle/manifest.yaml)
set -euo pipefail
cd "$(dirname "$0")/.."

out=${BUNDLE_DIR:-$PWD/.local-runtime/bundle}
manifest=${BUNDLE_MANIFEST:-bundle/manifest.yaml}
m() { yq -r "$1" "$manifest"; }
fetch() { [[ -s $2 ]] || { mkdir -p "$(dirname "$2")"; curl -fsSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"; }; }
# A target image name as a file name: calico/node:v1 -> calico_node_v1.tar
image_file() { echo "$out/images/$(tr '/:' '__' <<<"$1").tar"; }

mkdir -p "$out"
cp "$manifest" "$out/manifest.yaml"

echo "Nexus $(m .nexus.version)"
fetch "$(m .nexus.source)" "$out/nexus.tar.gz"

echo 'Kubemarine files'
m '.files | to_entries[] | .key + " " + .value' | while read -r path url; do fetch "$url" "$out/files/$path"; done

echo "Node packages from $(m .os.image)"
if [[ ! -s $out/apt/Packages ]]; then
    # The closure is resolved in a clean container of the node OS release; virtual packages have no candidate.
    cid=$(docker create "$(m .os.image)" bash -c '
        set -eu
        apt-get update -qq && apt-get install -y -qq --no-install-recommends apt-utils >/dev/null
        mkdir -p /debs && chmod 777 /debs && cd /debs
        apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces \
            --no-enhances "$@" | grep -E "^[a-z0-9]" | sort -u > /tmp/names
        apt-get download -qq $(xargs apt-cache policy < /tmp/names |
            awk "/^[a-z0-9].*:\$/ {n=\$1} /Candidate:/ && \$2 != \"(none)\" {sub(\":\$\",\"\",n); print n}")
        apt-ftparchive packages . > Packages' bash $(m '.os.packages[]'))
    docker start -a "$cid" >/dev/null
    rm -rf "$out/apt" && docker cp "$cid:/debs" "$out/apt"
    docker rm "$cid" >/dev/null
fi

echo 'Helm charts'
mkdir -p "$out/charts"
m '.charts[] | .chart + " " + .version + " " + .repository' | while read -r chart version repository; do
    [[ -s $out/charts/$chart-$version.tgz ]] ||
        helm pull "$chart" --repo "$repository" --version "$version" --destination "$out/charts"
done
helm repo index "$out/charts"

echo 'Images'
m '(.images | to_entries[] | .key + " " + .value), (.app_images[] | . + " " + .)' | while read -r target source; do
    file=$(image_file "$target")
    [[ -s $file ]] || { mkdir -p "$out/images"; crane pull --platform linux/amd64 "$source" "$file.part" && mv "$file.part" "$file"; }
done

echo "Bundle ready: $out ($(du -sh "$out" | cut -f1)). Move it as is (or as one tar) to the operator machine."
