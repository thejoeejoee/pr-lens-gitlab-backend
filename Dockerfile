# syntax=docker/dockerfile:1

# Pinned to a minor so the Alpine underneath cannot change on a rebuild, while
# node and alpine patch releases still arrive. Not a digest: a digest without an
# automated updater rots, and a stale digest is worse than a floating patch.
#
# Written out three times rather than held in an ARG, because Dependabot's
# Docker parser reads literal FROM lines only and skips a variable one
# entirely. Three lines it can bump together beat one line nobody bumps.

# Built rather than run from source, so the runtime image needs no TypeScript
# and no experimental flags.
FROM node:26-alpine3.22 AS build
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts because `prepare` builds, and src is not here yet. The
# explicit build below is the one that counts.
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# Production dependencies on their own, so the runtime stage copies them rather
# than installing again. Under QEMU that second install is the slowest thing in
# a multi-platform build.
FROM node:26-alpine3.22 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && \
    npm cache clean --force

FROM node:26-alpine3.22
ENV NODE_ENV=production
WORKDIR /app

# The store is git invocations, so git is a runtime dependency rather than a
# convenience -- about 15 MB, against a pure-JS implementation of the same
# thing that would have to get packfile negotiation and ref locking right.
RUN apk add --no-cache git

# package.json comes along because "type": "module" is what makes dist/*.js ESM.
COPY package.json ./
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

USER node
EXPOSE 8787

# node is PID 1 with no init wrapper, which is fine here for two reasons: the
# process installs its own SIGTERM and SIGINT handlers, and it never forks, so
# there are no orphans for an init to reap.
#
# The check speaks to /healthz rather than /readyz so that an unreachable GitLab
# does not restart a healthy process, and uses node's own fetch so the image
# needs neither curl nor wget.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
