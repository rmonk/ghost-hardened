# Hardened Ghost image: upstream's official image for the same release (pinned by digest), with
# what Ghost never runs at runtime removed, current Debian packages, and a fixed non-root uid as
# the default user. Ghost itself (/var/lib/ghost/versions/<version>), the entrypoint, CMD, env,
# config and content layout are upstream's.
#
# Removed (none of it is used by a running Ghost):
#   - gosu: upstream starts as root and drops to `node` (uid 1000) with it; this image starts as
#     uid 2368, so the entrypoint takes its non-root branch and gosu is never needed
#   - global npm/npx, corepack and its pnpm/yarn shims, yarn v1 (/opt/yarn-*)
#   - /var/lib/ghost/.pnpm-store: the package manager's build cache (584 MB at 6.78.0), which
#     also holds a stray Go binary. node_modules keep their own copies of the files they use.
#
# Build args come from build/build-args (scripts/prepare.sh).

ARG UPSTREAM_IMAGE
FROM ${UPSTREAM_IMAGE}

ARG UPSTREAM_VERSION
ARG UPSTREAM_DIGEST
ARG HARDENED_VERSION=dev
ARG HARDENED_SOURCE=
# Fixed IDs; upstream's `node` is uid 1000, which is a real user on futomaki.
ARG GHOST_UID=2368
ARG GHOST_GID=2368

USER root
# Anchors: fail instead of shipping something that only looks hardened if upstream changes how
# the image starts. The entrypoint must keep its non-root branch (it seeds the content volume
# from content.orig without gosu) and Ghost must be the installed version.
RUN set -eu; \
    e=/usr/local/bin/docker-entrypoint.sh; \
    grep -qF '# allow the container to be started with `--user`' "$e"; \
    grep -qE '^if \[\[ "\$\*" == node\*current/index\.js\* \]\]; then$' "$e"; \
    grep -qF 'baseDir="$GHOST_INSTALL/content.orig"' "$e"; \
    [ "$(readlink /var/lib/ghost/current)" = "/var/lib/ghost/versions/${UPSTREAM_VERSION}" ]; \
    [ -d /var/lib/ghost/content.orig/themes ]; \
    apt-get update; \
    apt-get upgrade -y; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /usr/local/bin/gosu /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
          /usr/local/bin/pnpm /usr/local/bin/pnpx /usr/local/bin/yarn /usr/local/bin/yarnpkg; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-v* \
           /var/lib/ghost/.pnpm-store; \
    groupadd -g "${GHOST_GID}" ghost; \
    useradd -u "${GHOST_UID}" -g "${GHOST_GID}" -M -d /var/lib/ghost -s /usr/sbin/nologin ghost; \
    node -e "require('/var/lib/ghost/current/package.json')"

LABEL org.opencontainers.image.title="ghost (hardened)" \
      org.opencontainers.image.version="${HARDENED_VERSION}" \
      org.opencontainers.image.source="${HARDENED_SOURCE}" \
      org.opencontainers.image.description="Ghost ${UPSTREAM_VERSION}: official image minus gosu/npm/yarn/pnpm store, current Debian, uid 2368" \
      org.ghost-hardened.upstream-version="${UPSTREAM_VERSION}" \
      org.ghost-hardened.upstream-digest="${UPSTREAM_DIGEST}"

# Upstream's image has no health check, and has no curl or wget, so node asks Ghost's admin site
# endpoint for a 200. It sends the host and scheme of Ghost's configured `url` (as the reverse proxy
# would), because Ghost redirects any other host to that url, and a redirect doesn't show that
# Ghost is actually serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["node", "-e", "const u = new URL(process.env.url || 'http://localhost:2368'); require('http').get({ host: '127.0.0.1', port: 2368, path: '/ghost/api/admin/site/', headers: { Host: u.host, 'X-Forwarded-Proto': u.protocol.slice(0, -1) } }, r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]

USER ${GHOST_UID}:${GHOST_GID}
