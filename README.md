# ghost-hardened

Takes the official [Ghost](https://github.com/TryGhost/Ghost) image (`docker.io/library/ghost`) for a release, pinned
by digest, removes what a running Ghost never uses, applies current Debian updates and makes a fixed non-root uid
the default user. Each build is gated on a Trivy scan and a smoke test, and the result is published to
`ghcr.io/rmonk/ghost`. Ghost itself is upstream's, file for file.

At 6.78.0 (tested 2026-11-18): Trivy findings went from 1 critical / 50 high (26 in `gosu`'s Go 1.24.6 runtime, 14
in a stray Go binary in the image's pnpm build cache, 10 in npm's own dependencies) to 0 fixable. What remains (1
critical, 37 high) is in Debian 12 packages with no fix released, which the official image's Node base brings.

## What gets changed

| | Official image | Hardened |
|---|---|---|
| Start | as root; entrypoint chowns the content volume and drops to `node` (uid 1000) with `gosu` | as uid/gid **2368** (`ghost`); the entrypoint takes its non-root branch, `gosu` is removed |
| Tooling | global npm/npx, corepack with pnpm/yarn shims, yarn v1 in `/opt` | removed (Ghost doesn't run them) |
| `/var/lib/ghost/.pnpm-store` | the package manager's build cache (584 MB), including a Go binary | removed (node_modules keep their own copies) |
| Debian packages | as built | `apt-get upgrade`, rebuilt weekly |
| Health check | none | `node` requests `/ghost/api/admin/site/` (any answer below 400) |

The Ghost install, entrypoint, CMD, environment, config and content layout are unchanged. The build fails if the
entrypoint loses its non-root branch (which seeds the content volume from `content.orig` without gosu) or if the
installed Ghost version doesn't match `UPSTREAM_VERSION`.

## Running it

```yaml
image: ghcr.io/rmonk/ghost:latest-hardened   # runs as 2368:2368 by default
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
read_only: true
tmpfs: [/tmp]
volumes:
  - ghost:/var/lib/ghost/content   # must be writable by 2368
```

Moving from the official image, once, with the container stopped: `chown -R 2368:2368 <content volume>` on the host.
Don't start this image as root: without gosu the entrypoint's root branch fails.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `6.78.0-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 06:47 UTC). It runs prepare (resolves the official image's
  digest), then build, then the Trivy gate (fixable CRITICAL/HIGH fail the build; exceptions go in
  `.trivyignore.yaml`, scoped to a package URL with a reason and an expiry date), then the smoke test, then pushes
  Docker v2 manifests (podman ignores HEALTHCHECK in OCI images) on main only. If the `HC_PING_URL` secret is set, a
  successful run pings it.
- `watch-upstream.yml`: runs daily. When a newer official image version tag appears on Docker Hub, it opens a PR that
  bumps `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Smoke test

`scripts/smoke-test.sh` starts the image with MySQL 8.4 and a dedicated database user, the way futomaki runs it (uid
2368, no capabilities, `no-new-privileges`, read-only root, tmpfs `/tmp`, a fresh content volume), and checks:
- uid 2368; gosu, npm, yarn, pnpm and the pnpm store are gone; Ghost reports the expected version
- the content volume is seeded with themes by the entrypoint's non-root branch
- first-run setup, admin session login, publishing a post and serving it
- an image upload is written to the content volume and served
- a recreate with the same volume keeps the post; the image's health check passes; no permission errors in the logs

## Local build

```bash
scripts/prepare.sh
podman build --format docker -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t ghost:hardened build/src      # --format docker: OCI images drop HEALTHCHECK
DOCKER=podman scripts/smoke-test.sh ghost:hardened
```
