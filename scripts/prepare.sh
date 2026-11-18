#!/usr/bin/env bash
# Resolve upstream's official Ghost image for UPSTREAM_VERSION to a digest and write
# build/build-args. The overlay's anchor checks run inside the build (overlay/Dockerfile).
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
image_repo="${UPSTREAM_IMAGE_REPO:-library/ghost}"

rm -rf "$root/build"
mkdir -p "$root/build/src"
token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image_repo:pull" | jq -r .token)"
digest="$(curl -fsSI -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry-1.docker.io/v2/$image_repo/manifests/$ref" \
  | tr -d '\r' | sed -nE 's/^docker-content-digest: *(sha256:[0-9a-f]{64})$/\1/Ip')"
[ -n "$digest" ] || { echo "prepare: could not resolve docker.io/$image_repo:$ref" >&2; exit 1; }
echo "prepare: base docker.io/$image_repo:$ref@$digest"

cp "$root/overlay/Dockerfile" "$root/build/src/Dockerfile.hardened"
cat > "$root/build/build-args" <<ARGS
UPSTREAM_IMAGE=docker.io/$image_repo:$ref@$digest
UPSTREAM_VERSION=$ref
UPSTREAM_DIGEST=$digest
ARGS
echo "prepare: build context ready at $root/build/src"
