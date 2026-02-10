#!/usr/bin/env bash
# Stream logs from the Rocket.Chat stack
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [SERVICE...]

Stream logs from the Rocket.Chat stack.

Component flags:
  --no-monitoring     Exclude monitoring services
  --no-traefik        Exclude Traefik services
  --monitoring-only   Show only monitoring service logs
  --traefik-only      Show only Traefik service logs
  --database-only     Show only database service logs
  --app-only          Show only Rocket.Chat + database logs

Options:
  -f, --follow        Follow log output (default)
  --no-follow         Print logs and exit
  --tail N            Number of lines to show from end (default: 100)
  --since TIME        Show logs since timestamp (e.g. "10m", "1h", "2024-01-01")
  -h, --help          Show this help message

Services:
  Optionally specify one or more service names to filter logs
  (e.g. rocketchat, mongodb, grafana, prometheus, nats)

Examples:
  $(basename "$0")                        # Follow all logs
  $(basename "$0") rocketchat             # Follow Rocket.Chat logs only
  $(basename "$0") --no-monitoring        # Follow logs without monitoring
  $(basename "$0") --tail 500 --no-follow # Print last 500 lines and exit
  $(basename "$0") --since 10m            # Logs from last 10 minutes
  $(basename "$0") mongodb rocketchat     # Follow MongoDB + Rocket.Chat logs
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
FOLLOW=true
TAIL="100"
SINCE=""
SERVICES=()

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
  esac
done

parse_component_flags "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--follow)    FOLLOW=true ;;
    --no-follow)    FOLLOW=false ;;
    --tail)
      shift
      if [[ $# -eq 0 ]]; then
        log_error "--tail requires a value"
        exit 1
      fi
      TAIL="$1"
      ;;
    --since)
      shift
      if [[ $# -eq 0 ]]; then
        log_error "--since requires a value"
        exit 1
      fi
      SINCE="$1"
      ;;
    -h|--help) usage ;;
    -*)
      log_error "Unknown option: $1"
      usage
      ;;
    *)
      SERVICES+=("$1")
      ;;
  esac
  shift
done

# ── Preflight ───────────────────────────────────────────────────────
run_checks

# Logs needs .env for traefik compose parsing
if [[ "${INCLUDE_TRAEFIK}" == "true" ]]; then
  ensure_env_file_for_down
fi

build_compose_files

# ── Build logs args ─────────────────────────────────────────────────
LOGS_ARGS=("logs")
[[ "${FOLLOW}" == "true" ]]  && LOGS_ARGS+=("--follow")
[[ -n "${TAIL}" ]]           && LOGS_ARGS+=("--tail" "${TAIL}")
[[ -n "${SINCE}" ]]          && LOGS_ARGS+=("--since" "${SINCE}")

# Append service names if specified
if [[ ${#SERVICES[@]} -gt 0 ]]; then
  LOGS_ARGS+=("${SERVICES[@]}")
fi

# ── Stream logs ─────────────────────────────────────────────────────
run_compose "${LOGS_ARGS[@]}"
