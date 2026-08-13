# syntax=docker/dockerfile:1

# ---- deps: resolve production dependencies ---------------------------------------
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS deps

WORKDIR /app

# Copied ahead of the source so this layer stays cached for any change that does not
# touch the dependency set.
COPY package.json package-lock.json ./

# `npm ci` installs exactly what the lockfile pins. `npm install` may resolve newer
# versions and would make the build non-reproducible.
RUN npm ci --omit=dev

# ---- runtime ---------------------------------------------------------------------
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS runtime

ENV NODE_ENV=production \
    PORT=8080

# PID 1 does not get default signal handling: the kernel only delivers a signal to it if
# the process installed a handler. app.js installs none, so as PID 1 node discards
# SIGTERM - `docker stop` measurably took the full 10s timeout and ended in SIGKILL, and
# in Kubernetes every pod deletion would burn terminationGracePeriodSeconds the same way.
#
# tini runs as PID 1 with correct default handling and forwards SIGTERM to node, which
# is then an ordinary process and terminates immediately. Fixing this in the image keeps
# it out of the application's code.
#
# The removals in the same layer: no package manager belongs in a runtime container.
# Dependencies are already resolved in the deps stage, and a package manager is a
# ready-made tool for pulling code into a compromised container.
#
# That removal is also load-bearing for the image scan. Every HIGH/CRITICAL finding in
# this base image comes from the dependency trees bundled with npm and corepack (tar
# CRITICAL, brace-expansion, ip-address, sigstore, picomatch) - not from Alpine, and not
# from this app. Deleting them clears those CVEs legitimately rather than suppressing
# them in a .trivyignore. yarn scans clean today but goes for the same reason.
#
# Single RUN so the deletions land in the same layer as the install; separate layers
# would leave the removed files recoverable in the image history.
RUN apk add --no-cache tini=~0.19 \
    && rm -rf /usr/local/lib/node_modules/npm \
              /usr/local/lib/node_modules/corepack \
              /usr/local/bin/npm \
              /usr/local/bin/npx \
              /usr/local/bin/corepack \
              /usr/local/bin/yarn \
              /usr/local/bin/yarnpkg \
              /opt/yarn-v*

WORKDIR /app

# --chown during COPY avoids an extra layer just to correct ownership.
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json app.js ./

# Numeric rather than `USER node`, though they are the same uid 1000 shipped by the base
# image. Kubernetes evaluates runAsNonRoot against the numeric id and cannot resolve a
# username from the image, so a named USER would leave the pod failing to start under
# runAsNonRoot: true unless runAsUser were also set.
USER 1000:1000

# Documentation only. The effective port comes from PORT and the chart's containerPort.
EXPOSE 8080

# Kubernetes ignores HEALTHCHECK and uses the probes in the chart instead, but this makes
# `docker run` and the CI smoke test self-verifying. Explicit `sh -c` in JSON form rather
# than shell form, so PORT is still expanded without the implicit-shell ambiguity.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/bin/sh", "-c", "wget -qO- \"http://127.0.0.1:${PORT}/live\" || exit 1"]

# tini at PID 1, node as its child. Exec form throughout: shell form would insert
# /bin/sh between them, which does not forward signals either.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "app.js"]
