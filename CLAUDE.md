# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Server Overview

- **Hostname:** `apps.molamphy.net`
- **OS:** Ubuntu 24.04.4 LTS
- **Resources:** 2 vCPU, 3.8 GB RAM, 1 GB swap, 64 GB disk
- **Docker:** v28.2.2 with Compose v5.0.2
- **All app management requires `sudo`** (Docker socket and `/root/` are root-owned)

## Architecture

All apps run in Docker via `docker compose`, each in its own directory under `/root/`. This is the established pattern for all new apps.

```
/root/
├── rocket.chat.server/   # Chat server (main app)
├── uptimekuma/           # Uptime monitoring
├── syncthing/            # File sync (linuxserver.io image)
├── endlessh/             # SSH tarpit on port 22 (endlessh-go)
├── goaccess/             # Web log dashboard (GoAccess + nginx)
├── launcher/             # Homepage/service dashboard (port 80)
├── librespeed/           # Network speed test (linuxserver.io image)
├── dotfiles/             # Shell config (not a Docker app)
└── powerlevel10k/        # Shell theme (not a Docker app)
```

## Networking & Access

**Firewall (UFW):** Only SSH (22) and the `tailscale0` interface are permitted. Docker bypasses UFW via its own iptables rules, so container ports bound to `0.0.0.0` are reachable on the host's public IP as well.

Additional UFW rules:
- `172.18.0.0/16 → port 9100/tcp` — allows Prometheus (on `rocketchatserver_default` bridge) to scrape node-exporter on the host

**TLS/HTTPS:** Handled by **Tailscale**, not Traefik. The Rocket.Chat compose stack includes a `compose.traefik.yml` but Traefik is intentionally skipped when Tailscale is active — `up.sh` detects this automatically. Always pass `--no-traefik` when calling `restart.sh` manually.

**Tailscale network:**
- Tailnet: `tail81bdee.ts.net`
- This machine: `apps.tail81bdee.ts.net` / `100.81.227.18`

All Tailscale serve endpoints are persisted in `/etc/systemd/system/tailscale-services.service` and start automatically after boot. To update endpoints, edit that file and run `sudo systemctl restart tailscale-services`.

| URL | Backend | Notes |
|---|---|---|
| `https://apps.tail81bdee.ts.net` | Launcher (port 4174) | device-level |
| `https://apps.tail81bdee.ts.net:8384` | Syncthing UI | device-level |
| `https://apps.tail81bdee.ts.net:7891` | GoAccess logs | device-level |
| `https://apps.tail81bdee.ts.net:8585` | LibreSpeed | device-level |
| `https://status.tail81bdee.ts.net` | Uptime Kuma (port 3001) | `svc:status` — ⚠️ see note below |
| `https://chat.tail81bdee.ts.net` | Rocket.Chat (port 3000) | `svc:chat`, managed by `up.sh` |

**Note:** `svc:*` service hostnames require one-time admin approval in the Tailscale console and do **not** appear in `tailscale serve status` (use `tailscale serve status --json` to see full config including services). The server cannot reach its own service URLs from localhost — test from another tailnet device.

**⚠️ svc:status known issue:** The Tailscale admin portal shows "needs configuration / required ports missing" for `svc:status` and the primary route is not being assigned to this node. Root cause unresolved. The launcher Status link currently bypasses this and points directly to `http://apps.molamphy.net:3001/status/all`.

**svc:\* gotchas learned:**
- All service ports **must** use `--https=X` (not `--http=X`) — even port 80. Using `--http=80` sets `"HTTP": true` in the TCP config; Tailscale services require `"HTTPS": true` on all ports.
- `tailscale serve clear svc:X` **removes the admin console approval**, requiring re-approval. Use `--https=X off` / `--https=Y off` to remove individual endpoints instead.
- Every RC stack restart (`up.sh`) used to wipe device-level serve endpoints (`--https=443 off` for the maintenance page). `up.sh` now calls `sudo systemctl restart tailscale-services` after startup to restore them.

## Running Services & Port Map

| Service | Port | Binding | Container |
|---|---|---|---|
| Launcher HTTP→HTTPS redirect | 80 | 0.0.0.0 | `launcher` |
| Launcher app (Tailscale internal) | 4174 | 127.0.0.1 | `launcher` |
| Rocket.Chat | 3000 | 0.0.0.0 | `rocketchatserver-rocketchat-1` |
| Uptime Kuma | 3001 | 0.0.0.0 | `uptime-kuma` |
| RC Metrics (Prometheus scrape) | 9458 | 0.0.0.0 | `rocketchatserver-rocketchat-1` |
| MongoDB | 27017 | 127.0.0.1 | `rocketchatserver-mongodb-1` |
| NATS | 4222 | 127.0.0.1 | `rocketchatserver-nats-1` |
| Prometheus | 9000 | 127.0.0.1 | `rocketchatserver-prometheus-1` |
| Grafana | 5050 | 127.0.0.1 | `rocketchatserver-grafana-1` |
| node-exporter | 9100 | host network | `rocketchatserver-node-exporter-1` |
| Syncthing Web UI | 8384 | 127.0.0.1 | `syncthing` |
| Syncthing sync | 22000 tcp+udp | 0.0.0.0 | `syncthing` |
| Syncthing discovery | 21027 udp | 0.0.0.0 | `syncthing` |
| endlessh (SSH tarpit) | 22 | 0.0.0.0 | `endlessh` |
| endlessh Prometheus metrics | 2112 | 127.0.0.1 | `endlessh` |
| GoAccess dashboard | 7891 | 127.0.0.1 | `goaccess-nginx` |
| GoAccess WebSocket | 7890 | internal only | `goaccess` |
| LibreSpeed | 3002 | 127.0.0.1 | `librespeed` |

**Exited containers (expected):** `mongodb-fix-permission-container` and `mongodb-init-container` are one-shot init containers — exited status is normal. `traefik-init-1` is also a one-shot init container.

## Nightly Updates

A cron job runs daily at **3:00 AM** as root:
```
0 3 * * * /usr/local/bin/docker-update.sh
```

Script: `/usr/local/bin/docker-update.sh`
Logs: `/var/log/docker-update/YYYY-MM-DD.log` (30-day retention)

**Simple stacks** (endlessh, goaccess, launcher, librespeed, syncthing, uptimekuma): pulls latest images, recreates only containers with new images.

**Rocket.Chat stack**: pulls all 3 active compose files together (`compose.database.yml` + `compose.monitoring.yml` + `compose.yml`), then compares running container image SHAs against freshly-pulled ones. If any image changed, calls `restart.sh --no-traefik` to bring the entire stack down and back up together (this also removes old images via `--rmi all` and re-registers Tailscale endpoints). If nothing changed, no restart occurs.

## App Management

### General pattern (all apps except Rocket.Chat)
```bash
sudo docker compose -f /root/<app>/compose.yml up -d
sudo docker compose -f /root/<app>/compose.yml down
sudo docker compose -f /root/<app>/compose.yml logs -f
sudo docker compose -f /root/<app>/compose.yml pull && sudo docker compose -f /root/<app>/compose.yml up -d
```

### Rocket.Chat (`/root/rocket.chat.server/`)

Has a split compose setup and wrapper scripts — always use the scripts, not `docker compose` directly:

```bash
sudo /root/rocket.chat.server/up.sh                      # Start full stack
sudo /root/rocket.chat.server/up.sh --app-only           # Start without monitoring
sudo /root/rocket.chat.server/down.sh                    # Stop full stack
sudo /root/rocket.chat.server/down.sh -v                 # Stop and delete volumes (prompts!)
sudo /root/rocket.chat.server/restart.sh --no-traefik    # Restart (always --no-traefik on this server)
                                                         # Default: removes all images (--rmi all), pulls fresh, brings up
sudo /root/rocket.chat.server/restart.sh --no-traefik --no-pull  # Restart without pulling (faster, uses cached images)
sudo /root/rocket.chat.server/logs.sh                    # Follow logs
sudo /root/rocket.chat.server/status.sh                  # Show status
```

Compose files:
- `compose.yml` — Rocket.Chat app
- `compose.database.yml` — MongoDB + NATS + exporters
- `compose.monitoring.yml` — Prometheus, Grafana, Loki, OpenTelemetry, node-exporter
- `compose.traefik.yml` — Traefik (unused when Tailscale is active)
- `.env` — All configuration; `.env.example` as reference

Key `.env` values: `DOMAIN`, `ROOT_URL`, `RELEASE`, `GRAFANA_ADMIN_PASSWORD`, `MONGODB_BIND_IP`.

### MongoDB Exporter — `$collStats` Collection List

`mongodb-exporter` is configured with `--mongodb.collstats-colls` to run `$collStats` on a specific list of collections rather than all of them. Running `$collStats` on all 87 collections (58 of which are empty unused-feature placeholders) caused 10–13 slow-query log entries per hour with zero monitoring value.

**Currently monitored collections** (in `compose.database.yml`):

| Collection | Why monitored |
|---|---|
| `rocketchat_message` | Core chat data — grows with every message sent |
| `rocketchat_cron_history` | Largest collection by doc count; grows continuously as jobs run |
| `rocketchat_server_events` | Audit log; grows with logins and admin actions |
| `rocketchat_sessions` | Active user sessions |
| `rocketchat_oembed_cache` | URL preview cache; can balloon silently as users share links |
| `rocketchat_avatars.chunks` | Binary avatar storage |
| `users` | User accounts |
| `rocketchat_room` | Rooms/channels |

**Revisit this list as usage grows.** Add collections to `--mongodb.collstats-colls` in `compose.database.yml` when these features are enabled:

- **More users** → add `rocketchat_subscription`, `rocketchat_message_reads`
- **File uploads** → add `rocketchat_uploads`, `rocketchat_avatars.files`
- **LiveChat / Omnichannel** → add `rocketchat_livechat_visitor`, `rocketchat_livechat_inquiry`, `rocketchat_livechat_contact`
- **Video calls** → add `rocketchat_video_conference`, `rocketchat_media_calls`
- **Apps / integrations** → add `rocketchat_apps_logs`, `rocketchat_integration_history`

To audit current collection sizes and find new growth candidates:
```bash
sudo docker exec rocketchatserver-mongodb-1 mongosh --quiet --norc --eval \
  'db.getSiblingDB("rocketchat").getCollectionNames().sort().forEach(function(n) { var s = db.getSiblingDB("rocketchat").getCollection(n).stats({scale:1024}); if(s.count > 0) print(n, s.size+"KB", s.count+"docs") })'
```

### Quick status check (all containers)
```bash
sudo docker ps -a
```

## Data & Volumes

Named Docker volumes (survive `down`, destroyed with `down -v`):
- `rocketchatserver_mongodb_data` — all chat data
- `rocketchatserver_prometheus_tsdb` — metrics history
- `rocketchatserver_grafana_data` — dashboards/alerts
- `rocketchatserver_loki_data` — log storage

Bind mounts:
- `/root/uptimekuma/data/` — Uptime Kuma data
- `/root/syncthing/config/` — Syncthing config; `/root/syncthing/data/` — synced files
- `/root/goaccess/report/` — generated HTML report; `/root/goaccess/data/` — persistent stats DB
- `/root/launcher/logs/` — nginx access + error logs (written by launcher, read by GoAccess)

## Launcher Dashboard (`/root/launcher/`)

**Starbase-80**, titled "Community Apps". `TITLE` and `LOGO` env vars are set in `compose.yml`. The container rebuilds the app on every start (~30s), so env var changes require `up -d`, not just `restart`. A `restart` is sufficient for `config.json` changes.

- Port 80 → HTTP redirect to `https://apps.tail81bdee.ts.net`
- Port 4174 → actual app content (Tailscale proxies this internally)
- nginx config: `/root/launcher/nginx/nginx.conf` (mounted), `/root/launcher/nginx/redirect.conf` (mounted)

Edit `/root/launcher/config.json` to add/update service links, then:
```bash
sudo docker compose -f /root/launcher/compose.yml restart
```

Icon names use the [walkxcode/dashboard-icons](https://github.com/walkxcode/dashboard-icons) CDN — names must match exactly (e.g. `rocket-chat`, `uptime-kuma`, `syncthing`, `librespeed`). Prefix with `selfhst-` for the selfhst/icons CDN instead.

## GoAccess Bot Detection (`/root/goaccess/`)

GoAccess runs with `--browsers-file=/browsers.list` and `--unknowns-as-crawlers`. The `browsers.list` file contains ~60 tab-separated patterns (`PATTERN\tCrawlers`) covering scanners, SEO bots, script UAs, and feed readers. Any UA not matching a known browser is also classified as a crawler.

**Format rules:** tab-separated, no comments, no blank lines, real tab characters (not spaces). Write entries with `printf "%s\t%s\n"` to guarantee correct tabs.

## Uptime Kuma Monitoring (`/root/uptimekuma/`)

To monitor a service internally, join Uptime Kuma to that app's Docker network by adding it as an external network in `/root/uptimekuma/compose.yml`, then use the container name as the hostname. Currently joined networks:
- `rocketchatserver_default` → monitor as `http://rocketchatserver-rocketchat-1:3000`
- `syncthing_default` → monitor as `http://syncthing:8384`

After editing the compose file: `sudo docker compose -f /root/uptimekuma/compose.yml up -d`

## Adding a New App

1. Create `/root/<appname>/` with a `compose.yml`
2. Use named volumes or bind mounts inside the app directory for persistence
3. Bind sensitive internal services to `127.0.0.1`; only expose public-facing ports to `0.0.0.0`
4. For HTTPS on the tailnet, add a `tailscale serve` line to `/etc/systemd/system/tailscale-services.service` and run `sudo systemctl restart tailscale-services`
5. For a named service hostname (e.g. `foo.tail81bdee.ts.net`), use `--service=svc:foo --https=443` AND `--service=svc:foo --https=80` — **all ports must use `--https=X`**. Requires one-time admin approval in the Tailscale console. Do NOT use `--http=X` for any service port.
6. Add it to `/root/launcher/config.json` and restart the launcher
7. Add it to the `SIMPLE_STACKS` array in `/usr/local/bin/docker-update.sh` for nightly updates
8. To monitor it in Uptime Kuma, add its Docker network to `/root/uptimekuma/compose.yml`
9. **Update this CLAUDE.md** — add the app to the directory tree, port map, Tailscale URL table, and any app-specific notes

> **Standing instruction:** Whenever a new app is deployed or removed, CLAUDE.md must be updated before the task is considered complete.

## Tailscale Serve

```bash
tailscale serve status                            # Shows device-level endpoints only (svc:* do NOT appear here)
tailscale serve status --json                     # Full config including svc:* services and TCP port modes
sudo systemctl restart tailscale-services         # Re-register all static endpoints (after reboot or changes)
sudo systemctl cat tailscale-services             # View current registered endpoints
tailscale serve advertise svc:<name>              # Re-advertise a service as primary after it was drained
```

**node-exporter scrape target:** Prometheus scrapes node-exporter at `172.18.0.1:9100` (the `rocketchatserver_default` bridge gateway). Config: `files/prometheus/file_sd_configs/node-exporter-docker.yml`. UFW rule allows `172.18.0.0/16 → 9100/tcp`. The `node-exporter-podman.yml` file (targets `host.containers.internal`) is irrelevant on this Docker host and always fails — ignore it.
