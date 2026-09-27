# UNCAGED Index Relay
#
# Multi-stage: a builder stage installs ALL dependencies (incl. devDeps for a
# typecheck gate) and runs `tsc --noEmit`; the runtime stage carries only
# production deps + source. The image deliberately runs as non-root.

FROM oven/bun:1 AS builder
WORKDIR /app

# Install dependencies (lockfile-first for reproducible builds)
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

# Copy source and typecheck. A type error fails the build here — never ship
# an image that doesn't compile.
COPY tsconfig.json biome.json ./
COPY src ./src
COPY scripts ./scripts
COPY public ./public
RUN bun run typecheck

# ---------------------------------------------------------------------------

FROM oven/bun:1 AS runtime
WORKDIR /app
ENV NODE_ENV=production

# Production dependencies only.
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

# Application source and assets.
COPY --from=builder /app/tsconfig.json ./tsconfig.json
COPY --from=builder /app/src ./src
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/public ./public

# Entrypoint: generates a relay signing key on first run when NOSTR_NSEC is
# unset (so the app works out of the box), prints it once, and persists it
# in the data dir so it survives restarts. nostr-tools (already a production
# dependency) provides the key generation; no extra packages are needed.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Non-root runtime user (oven/bun alpine user `bun`, uid 1000). /app/data is
# the volume mount point for the generated key (and anything else the relay
# persists). If the mounted volume is root-owned, docker-entrypoint.sh degrades
# gracefully (ephemeral key + warning) — or use the compose init service that
# chowns the data dir before start.
RUN mkdir -p /app/data && chown -R bun:bun /app
USER bun

EXPOSE 13131

# Liveness via the /healthz endpoint. NB: oven/bun images are Alpine and ship
# busybox wget, NOT curl.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:13131/healthz || exit 1

ENTRYPOINT ["sh", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["bun", "src/server.ts"]
