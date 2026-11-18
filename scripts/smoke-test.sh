#!/usr/bin/env bash
# Start the image with MySQL 8.4 the way futomaki runs it (uid 2368 by default, no capabilities,
# no-new-privileges, read-only root, tmpfs /tmp, fresh content volume, a dedicated database user),
# then check:
#   - it runs as uid 2368, gosu/npm/yarn/pnpm are gone, Ghost is the expected version
#   - the content volume is seeded from content.orig (themes) by the entrypoint's non-root branch
#   - first-run setup, admin session login, publishing a post, the public post page
#   - an image upload is written to the content volume and served
#   - a restart keeps the post; the image's health check passes; no permission errors in the logs
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs curl + jq)
set -euo pipefail
trap 'echo "smoke: FAIL command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
root="$(cd "$(dirname "$0")/.." && pwd)"
want_version="$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")"
tag="ghost-smoke-$$"
net="$tag-net"
port="${SMOKE_PORT:-12368}"
base="http://127.0.0.1:$port"
jar="$(mktemp)"
dbpass="db$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
password="Pw-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then echo "--- logs ---"; $docker logs --tail 60 "$tag" 2>&1 || true; fi
  $docker rm -f "$tag" "$tag-db" >/dev/null 2>&1 || true
  $docker volume rm -f "$tag-content" >/dev/null 2>&1 || true
  $docker network rm "$net" >/dev/null 2>&1 || true
  rm -f "$jar"
  exit $rc
}
trap cleanup EXIT

$docker network create "$net" >/dev/null
$docker run -d --name "$tag-db" --network "$net" --network-alias db \
  -e MYSQL_ROOT_PASSWORD="root-$dbpass" -e MYSQL_DATABASE=ghost -e MYSQL_USER=ghost -e MYSQL_PASSWORD="$dbpass" \
  docker.io/library/mysql:8.4 >/dev/null
for _ in $(seq 90); do
  $docker exec "$tag-db" mysql -ughost -p"$dbpass" -e 'select 1' ghost >/dev/null 2>&1 && break; sleep 2
done

start() {
  $docker run -d --name "$tag" --network "$net" \
    --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
    -e url="$base" -e database__client=mysql -e database__connection__host=db \
    -e database__connection__user=ghost -e database__connection__password="$dbpass" \
    -e database__connection__database=ghost -e security__staffDeviceVerification=false \
    -v "$tag-content:/var/lib/ghost/content" -p "127.0.0.1:$port:2368" "$image" >/dev/null
  for _ in $(seq 120); do
    curl -fsS -o /dev/null "$base/ghost/api/admin/site/" 2>/dev/null && return 0; sleep 2
  done
  echo "smoke: FAIL Ghost did not answer /ghost/api/admin/site/"; return 1
}
admin() {  # admin <method> <path> [curl args...] -> body; fails on HTTP >= 400
  local m="$1" p="$2"; shift 2
  curl -fsS -b "$jar" -c "$jar" -X "$m" -H "Origin: $base" -H 'Accept-Version: v6.0' "$@" "$base/ghost/api/admin$p"
}

start

uid="$($docker exec "$tag" sh -c 'stat -c %u /proc/1')"
[ "$uid" = 2368 ] || { echo "smoke: FAIL runs as uid $uid, expected 2368"; exit 1; }
for b in gosu npm npx corepack pnpm yarn; do
  $docker exec "$tag" sh -c "command -v $b" >/dev/null 2>&1 && { echo "smoke: FAIL $b is still in the image"; exit 1; }
done
$docker exec "$tag" test ! -e /var/lib/ghost/.pnpm-store || { echo "smoke: FAIL .pnpm-store still present"; exit 1; }
version="$(admin GET /site/ | jq -r .site.version)"
[ "${want_version%.*}" = "$version" ] || [ "$want_version" = "$version" ] \
  || { echo "smoke: FAIL Ghost reports version $version, expected $want_version"; exit 1; }
$docker exec "$tag" test -d /var/lib/ghost/content/themes/casper || $docker exec "$tag" sh -c 'ls /var/lib/ghost/content/themes | grep -q .' \
  || { echo "smoke: FAIL content volume was not seeded with themes"; exit 1; }
echo "smoke: uid 2368, no gosu/npm/yarn/pnpm, Ghost $version, content seeded"

admin POST /authentication/setup/ -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$password" '{setup:[{name:"Smoke",email:"smoke@example.com",password:$p,blogTitle:"Smoke"}]}')" >/dev/null
admin POST /session/ -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$password" '{username:"smoke@example.com",password:$p}')" >/dev/null
admin GET /users/me/ | jq -e '.users[0].email == "smoke@example.com"' >/dev/null \
  || { echo "smoke: FAIL admin session does not work"; exit 1; }
slug="$(admin POST '/posts/?source=html' -H 'Content-Type: application/json' \
  -d '{"posts":[{"title":"Smoke post","html":"<p>smoke-test-body</p>","status":"published"}]}' | jq -r '.posts[0].slug')"
curl -fsS "$base/$slug/" | grep -q 'smoke-test-body' || { echo "smoke: FAIL published post not served"; exit 1; }
echo "smoke: setup, admin login, post published and served"

png="$(mktemp --suffix .png)"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$png"
img="$(admin POST /images/upload/ -F "file=@$png;type=image/png" -F purpose=image | jq -r '.images[0].url')"
rm -f "$png"
curl -fsS -o /dev/null "$img" || { echo "smoke: FAIL uploaded image not served ($img)"; exit 1; }
$docker exec "$tag" sh -c 'find /var/lib/ghost/content/images -name "*.png" | grep -q .' \
  || { echo "smoke: FAIL uploaded image not in the content volume"; exit 1; }
echo "smoke: image upload written to the content volume and served"

$docker stop -t 20 "$tag" >/dev/null
$docker rm "$tag" >/dev/null
start
curl -fsS "$base/$slug/" | grep -q 'smoke-test-body' || { echo "smoke: FAIL post missing after restart"; exit 1; }
echo "smoke: restart keeps the post"

# The image's HEALTHCHECK must exist and pass. (podman keeps it only in Docker-format images:
# build with `--format docker`; CI pushes Docker v2 manifests for the same reason.)
hc="$($docker image inspect --format '{{json .Config.Healthcheck}}' "$image" \
  | jq -r '.Test // empty | if .[0] == "CMD-SHELL" then ["sh", "-c", .[1]] else .[1:] end | @sh')"
[ -n "$hc" ] || { echo "smoke: FAIL the image has no health check"; exit 1; }
eval "$docker exec \"$tag\" $hc" >/dev/null || { echo "smoke: FAIL the image's health check fails"; exit 1; }
echo "smoke: image health check passes"

logs="$($docker logs "$tag" 2>&1)"
if grep -qiE 'EACCES|EROFS|permission denied|read-only file system' <<<"$logs"; then
  grep -iE 'EACCES|EROFS|permission denied|read-only file system' <<<"$logs" | head -5
  echo "smoke: FAIL permission error in logs"; exit 1
fi
echo "smoke: PASS"
