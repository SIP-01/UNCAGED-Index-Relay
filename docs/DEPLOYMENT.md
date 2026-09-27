# Deploying the UNCAGED Index Relay

Three supported paths, easiest first:

1. **Umbrel** — one-click from the app store (or local install of this repo's
   `umbrel/` package)
2. **Docker Compose** — any VPS/home server
3. **Bare Bun + managed OpenSearch** — production tuning

---

## 1. Umbrel

### Prerequisite (one-time, on the Umbrel host)

OpenSearch's production bootstrap checks want
`vm.max_map_count ≥ 262144`. Most distros default to 65530. On your Umbrel
box (SSH):

```bash
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

Without it, the OpenSearch container logs
`max virtual memory areas vm.max_map_count [...] is too low` and exits.

### From the Umbrel App Store (once published)

Community Apps → search "UNCAGED Index Relay" → Install. Done.

### Local install (works today, from this repo)

The `umbrel/` directory is a complete Umbrel app package (manifest +
compose + gallery). To install it on your Umbrel:

```bash
# 1. Put the package where Umbrel keeps app sources
cp -r umbrel ~/umbrel/apps/uncaged-index-relay

# 2. The package pulls ghcr.io/nostrdanish/uncaged-index-relay:latest.
#    To build locally instead, edit umbrel/docker-compose.yml and replace
#    the relay `image:` line with:
#      build: { context: ../.., dockerfile: Dockerfile }
#    (after copying this whole repo, not just umbrel/)

# 3. Start it with Umbrel's compose (it injects $APP_DATA_DIR etc.)
cd ~/umbrel/apps/uncaged-index-relay
docker compose up -d
```

### After install

- **Relay URL**: `ws://umbrel.local:13131` on your LAN. To serve it beyond
  your LAN, use your Umbrel **Tor hidden service** (shown on the app's page
  in the Umbrel UI) and set `RELAY_URL`/`PUBLIC_URL` in the compose file to
  its `ws://…onion/` form — Tor is the natural fit for a
  censorship-resistant index relay. Restart the app after changing env vars.
- **First-run key**: the relay auto-generates its signing key, prints it
  **once** in the logs, and persists it in the app data dir
  (`…/uncaged-index-relay/relay/relay-secret.env`). Back it up if you care
  about the relay's identity for NIP-85/trends events; the SIP-01 index
  itself doesn't depend on it.
- **Data persistence**: OpenSearch data lives in the app's data folder
  (`…/uncaged-index-relay/opensearch`) — updates and restarts keep your
  index.
- **Verify**:

  ```bash
  curl http://umbrel.local:13131/healthz                     # → ok
  curl -H 'Accept: application/nostr+json' \
       http://umbrel.local:13131 | jq .uncaged_index         # capabilities
  ```

### Making your index relay discoverable

The NIP-11 document advertises your index scope (`uncaged_index.scope`,
`domains`, …). Configure specialization via environment overrides in
`umbrel/docker-compose.yml` (e.g. `UNCAGED_SCOPE=eu`,
`UNCAGED_DOMAINS=github.com`). Then list your relay's URL in Crawlstr's
relay pool and the search engines' search-relay config so crawlers publish
to you and engines query you.

### Umbrel resource notes

- **OpenSearch heap** defaults to 1 GB (`OPENSEARCH_JAVA_OPTS`) — safe on a
  4 GB Umbrel. Raise to `-Xms2g -Xmx2g` on bigger boxes handling real crawl
  load; keep it ≤ 50% of container memory.
- **ARM**: OpenSearch 2.x publishes `linux/arm64` images, so Raspberry Pi
  Umbrel boxes work — but crawling-scale indexing on a Pi will be slow.
  Treat a Pi as a federation/consumption node, not a primary crawl target.
- The relay process itself is lightweight (Bun, a few worker threads);
  `PROTOCOL_WORKERS` defaults to `cores/4`.
- If OpenSearch repeatedly restarts, check `docker logs` for the
  bootstrap-check message above, and confirm memory ≥ 4 GB.

---

## 2. Docker Compose (any server)

```bash
git clone https://github.com/NostrDanish/UNCAGED-Index-Relay.git
cd UNCAGED-Index-Relay

# Set your public relay URL (what clients will connect to)
echo 'RELAY_URL=wss://index.example.com/' >> .env

docker compose up -d
```

The relay listens on `:13131`. Put a TLS-terminating reverse proxy in front
(Caddy/nginx/traefik) that upgrades WebSocket connections and forwards the
client IP via `X-Forwarded-For` (the compose file already sets
`IP_HEADER`). Publishing a prebuilt image to a registry and using it
directly is the recommended production path.

## 3. Bare Bun (production tuning)

Prerequisites: OpenSearch 2.x (or a managed service), [Bun](https://bun.sh).

```bash
bun install
cp .env.example .env   # set RELAY_URL, NOSTR_NSEC (see .env.example for all)
bun run typecheck      # sanity gate
bun start
```

### Production checklist

- **TLS**: terminate at a reverse proxy; the relay speaks plain HTTP/WS.
- **OpenSearch auth**: on any shared network, enable the security plugin
  and set `OPENSEARCH_USERNAME`/`OPENSEARCH_PASSWORD`.
- **Backups**: the OpenSearch index is a cache — it can be rebuilt from
  Nostr (re-crawl / NIP-77 sync from peers). Back up the relay signing key
  (`relay-secret.env` or your `NOSTR_NSEC`) if you value the relay identity.
- **Shards/replicas**: defaults (3 shards, 1 replica) suit a single-node
  deployment; tune in `src/opensearch.ts` for large clusters.
- **Monitoring**: Prometheus metrics at `/metrics`; liveness at `/healthz`.
- **Umbrel restart semantics**: `restart: on-failure` + healthchecks — the
  relay does not crash-loop if OpenSearch is briefly down (its `event()`
  path applies backpressure instead of dying), and OpenSearch's
  `start_period: 90s` covers JVM boot.

---

## Verifying a deployment end-to-end

```bash
# 1. Liveness
curl -s http://localhost:13131/healthz

# 2. NIP-11 capabilities (SIP-01 advertisement)
curl -s -H 'Accept: application/nostr+json' http://localhost:13131 \
  | jq '{name, software, uncaged_index}'

# 3. Publish a test SIP-01 observation (kind 39697) with any Nostr client
#    that speaks the protocol (see docs/SIP-01.md §1 for the event shape),
#    then query it back:

# baseline (works on any relay):
#   REQ {"kinds":[39697],"limit":10}
# accelerated (this relay):
#   REQ {"kinds":[39697],"search":"example site:github.com lang:en"}
```

## Federation

Point a second relay at this one via NIP-77 Negentropy sync
(`["NEG-OPEN", "sync", {"kinds":[39697]}, <hex>]`) — indexes replicate
without a central master. See docs/SIP-01.md §6.
