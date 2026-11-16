#!/usr/bin/env bash
# Prints the bundle contents as Markdown for the GitHub release notes: every component with its version and source.
# Reads the manifest copied into a built bundle and the resolved package versions from its apt repository.
#   BUNDLE_DIR  bundle directory (default .local-runtime/bundle)
set -euo pipefail
cd "$(dirname "$0")/.."

bundle=${BUNDLE_DIR:-$PWD/.local-runtime/bundle}
m() { yq -r "$1" "$bundle/manifest.yaml"; }

cat <<EOF
## Contents

| Component | Version | Source |
|---|---|---|
| Nexus Repository | $(m .nexus.version) | [download]($(m .nexus.source)) |
| Kubemarine | $(m .kubemarine.version) | [PyPI](https://pypi.org/project/kubemarine/$(m .kubemarine.version)/) |
| Kubernetes | $(m .kubemarine.kubernetes_version) | [release](https://github.com/kubernetes/kubernetes/releases/tag/$(m .kubemarine.kubernetes_version)) |

### Kubernetes binaries

| File | Source |
|---|---|
EOF
m '.files | to_entries[] | "| `" + .key + "` | [" + .value + "](" + .value + ") |"'

cat <<EOF

### Node packages ($(m .os.image), with their dependencies)

| Package | Version | Source |
|---|---|---|
EOF
for pkg in $(m '.os.packages[]'); do
    version=$(awk -v p="$pkg" '$1 == "Package:" {n = $2} $1 == "Version:" && n == p {print $2; exit}' "$bundle/apt/Packages")
    echo "| $pkg | ${version:-?} | [packages.ubuntu.com](https://packages.ubuntu.com/search?keywords=$pkg) |"
done

cat <<'EOF'

### Helm charts

| Chart | Version | Repository |
|---|---|---|
EOF
m '.charts[] | "| " + .chart + " | " + .version + " | [" + .repository + "](" + .repository + ") |"'

cat <<'EOF'

### Images

| Image in Nexus | Source |
|---|---|
EOF
m '(.images | to_entries[] | "| `" + .key + "` | `" + .value + "` |"), (.app_images[] | "| `" + . + "` | `" + . + "` |")'
