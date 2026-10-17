#!/usr/bin/env bash
#
# start.sh - Launch local Google Antigravity telemetry dashboard server.
#
# Usage:
#   ./start.sh [PORT]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-${PORT:-8085}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "ERROR: invalid port '${PORT}'." >&2
  exit 1
fi
command -v node > /dev/null || { echo "ERROR: node (v18+) is required." >&2; exit 1; }

# If data doesn't exist, fetch it first
if [[ ! -f "${SCRIPT_DIR}/data/telemetry.json" ]]; then
  echo "Initial data not found. Fetching from BigQuery..."
  "${SCRIPT_DIR}/fetch_data.sh"
fi

PID_FILE="${SCRIPT_DIR}/server.pid"
if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}")"
  if kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "Dashboard server already running on PID ${OLD_PID} (see server.log for its port). Use ./stop.sh first to restart."
    exit 0
  else
    rm -f "${PID_FILE}"
  fi
fi

echo "Starting local telemetry dashboard server on port ${PORT}..."
# setsid (Linux) fully detaches the server from this shell's session/process group.
DETACH=()
command -v setsid > /dev/null && DETACH=(setsid)
"${DETACH[@]+"${DETACH[@]}"}" nohup node "${SCRIPT_DIR}/server.mjs" "${PORT}" > "${SCRIPT_DIR}/server.log" 2>&1 < /dev/null &
NEW_PID=$!
echo "${NEW_PID}" > "${PID_FILE}"

sleep 1
if kill -0 "${NEW_PID}" 2>/dev/null; then
  echo "Dashboard server started successfully (PID ${NEW_PID})."
  echo ""
  echo "=== Access Links ==="
  if [[ "${HOST:-127.0.0.1}" == "127.0.0.1" || "${HOST:-}" == "localhost" ]]; then
    echo "Local URL: http://localhost:${PORT}   (this machine only)"
    echo "From another machine: ssh -L ${PORT}:localhost:${PORT} $(hostname -f 2>/dev/null || hostname)"
    echo "  then open http://localhost:${PORT}, or restart with HOST=0.0.0.0 ./start.sh ${PORT}"
  else
    echo "Workstation URL: http://$(hostname -f 2>/dev/null || hostname):${PORT}   (reachable from the network; no login)"
    echo "Localhost URL:   http://localhost:${PORT}"
  fi
  echo "===================="
else
  echo "Failed to start server. Check logs:" >&2
  cat "${SCRIPT_DIR}/server.log" >&2
  exit 1
fi
