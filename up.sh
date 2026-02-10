#!/usr/bin/env bash
# Bring the Rocket.Chat stack up
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start the Rocket.Chat stack.

Component flags:
  --no-monitoring     Exclude monitoring (Prometheus, Grafana, Loki)
  --no-traefik        Exclude Traefik reverse proxy
  --monitoring-only   Start only database + monitoring
  --traefik-only      Start only database + Traefik
  --database-only     Start only database (MongoDB + NATS)
  --app-only          Start only database + Rocket.Chat (no monitoring/traefik)

Options:
  --pull              Pull latest images before starting
  --no-detach         Run in foreground (don't pass -d to compose)
  -h, --help          Show this help message

Examples:
  $(basename "$0")                        # Start full stack
  $(basename "$0") --no-monitoring        # Start without monitoring
  $(basename "$0") --pull                 # Pull images then start
  $(basename "$0") --database-only        # Start only MongoDB + NATS
EOF
  exit 0
}

# ── Source shared library ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/scripts/_common.sh" ]]; then
  # shellcheck source=scripts/_common.sh
  source "${SCRIPT_DIR}/scripts/_common.sh"
elif [[ -f "${SCRIPT_DIR}/_common.sh" ]]; then
  # shellcheck source=scripts/_common.sh
  source "${SCRIPT_DIR}/_common.sh"
else
  echo "ERROR: Cannot find scripts/_common.sh" >&2
  exit 1
fi

# ── Parse arguments ─────────────────────────────────────────────────
PULL=false
DETACH=true

# Check for --help before component parsing
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
  esac
done

parse_component_flags "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull)       PULL=true ;;
    --no-detach)  DETACH=false ;;
    -h|--help)    usage ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
  shift
done

# ── Preflight ───────────────────────────────────────────────────────
run_checks

if ! ensure_env_file; then
  exit 1
fi

# ── Tailscale + Traefik conflict detection ─────────────────────────
# Tailscale serve binds port 443 for TLS termination. Traefik also
# wants 0.0.0.0:443. They can't coexist — auto-skip Traefik when
# tailscale is handling serve (it provides TLS certs automatically).
USE_TAILSCALE=false
if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
  USE_TAILSCALE=true
  if [[ "${INCLUDE_TRAEFIK}" == "true" ]]; then
    log_warn "Tailscale detected — skipping Traefik (both need port 443)"
    log_warn "Tailscale serve handles TLS automatically for tailnet domains"
    INCLUDE_TRAEFIK=false
  fi
fi

build_compose_files
print_component_summary "starting"

# ── Pull images ─────────────────────────────────────────────────────
if [[ "${PULL}" == "true" ]]; then
  log_info "Pulling latest images..."
  run_compose pull
fi

# ── Stop nginx (frees port 80 for stack) ───────────────────────────
if systemctl is-active --quiet nginx 2>/dev/null; then
  log_info "Stopping nginx (frees port 80)..."
  sudo systemctl stop nginx
  log_ok "nginx stopped"
fi

# ── Stop tailscale serve (frees port 443 during startup) ──────────
if [[ "${USE_TAILSCALE}" == "true" ]]; then
  sudo tailscale serve --https=443 --set-path=/rocketchat off 2>/dev/null || true
fi

# ── Clean up orphan containers (e.g. Traefik from previous runs) ──
log_info "Removing orphan containers from previous runs..."
# Use all compose files for cleanup so orphan detection is accurate
CLEANUP_FILES=("-f" "compose.database.yml")
[[ -f "${REPO_ROOT}/compose.monitoring.yml" ]] && CLEANUP_FILES+=("-f" "compose.monitoring.yml")
[[ -f "${REPO_ROOT}/compose.traefik.yml" ]]    && CLEANUP_FILES+=("-f" "compose.traefik.yml")
[[ -f "${REPO_ROOT}/compose.yml" ]]            && CLEANUP_FILES+=("-f" "compose.yml")
# Ensure .env exists for traefik compose parsing
ensure_env_file_for_down
${COMPOSE_CMD} "${CLEANUP_FILES[@]}" down --remove-orphans 2>/dev/null || true

# ── Start stack ─────────────────────────────────────────────────────
UP_ARGS=("up")
if [[ "${DETACH}" == "true" ]]; then
  UP_ARGS+=("-d")
fi

run_compose "${UP_ARGS[@]}"

# ── Tailscale Serve ────────────────────────────────────────────────
if [[ "${USE_TAILSCALE}" == "true" ]]; then
  log_info "Starting Tailscale serve (https:443/rocketchat -> localhost:3000)..."
  sudo tailscale serve --bg --https=443 --set-path=/rocketchat http://localhost:3000
  log_ok "Tailscale serve started (https:443/rocketchat -> localhost:3000)"
fi

if [[ "${DETACH}" == "true" ]]; then
  print_access_urls
fi
