# GL.iNet Cross-Model Backup — Docker/controller edition.
#
# Node/Express is orchestration only. The canonical native runtime
# (runtime/native, pinned to main) is streamed to managed routers over SSH;
# no router-side package is required. This image therefore carries no IPK/APK
# tooling and never reimplements backup/restore policy in JavaScript.
#
# Multi-stage: dependencies are installed in a builder that has the toolchain
# ssh2's OPTIONAL native modules (cpu-features/nan) need when no prebuild is
# available; the runtime image receives only the production node_modules and
# the read-only application tree.

FROM node:22-alpine AS deps
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:22-alpine
ENV NODE_ENV=production
ENV DATA_DIR=/data
WORKDIR /app

# Application source is root-owned and read-only (a+rX); the runtime user
# writes only /data and /tmp. No git metadata, tests, docs, secrets, or local
# data are copied (see .dockerignore).
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY server.js ./
COPY lib ./lib
COPY public ./public
COPY runtime ./runtime

# Non-root runtime user. The official node image ships the `node` user (uid
# 1000). /data is created and owned by that user so profiles, jobs, sessions,
# and logs persist without privilege.
RUN mkdir -p /data \
 && chown -R node:node /data \
 && chown -R root:root /app \
 && chmod -R a+rX /app

USER node
EXPOSE 8787

# Node-based healthcheck (no curl dependency): /api/health is unauthenticated
# and carries no sensitive information.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8787/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Direct node entrypoint (no npm wrapper): signals reach the process and the
# server's SIGTERM/SIGINT handler closes the HTTP server gracefully.
CMD ["node", "server.js"]
