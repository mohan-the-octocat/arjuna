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

# If data doesn't exist, fetch it first
if [[ ! -f "${SCRIPT_DIR}/data/telemetry.json" ]]; then
  echo "Initial data not found. Fetching from BigQuery..."
  "${SCRIPT_DIR}/fetch_data.sh"
fi

PID_FILE="${SCRIPT_DIR}/server.pid"
if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}")"
  if kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "Dashboard server already running on PID ${OLD_PID}."
    echo "External URL: http://$(hostname -f):${PORT}"
    exit 0
  else
    rm -f "${PID_FILE}"
  fi
fi

echo "Starting local telemetry dashboard server on port ${PORT}..."
nohup node "${SCRIPT_DIR}/server.mjs" "${PORT}" > "${SCRIPT_DIR}/server.log" 2>&1 &
NEW_PID=$!
echo "${NEW_PID}" > "${PID_FILE}"

sleep 1
if kill -0 "${NEW_PID}" 2>/dev/null; then
  echo "Dashboard server started successfully (PID ${NEW_PID})."
  echo ""
  echo "=== Access Links ==="
  echo "Workstation URL: http://$(hostname -f):${PORT}"
  echo "Localhost URL:   http://localhost:${PORT}"
  echo "===================="
else
  echo "Failed to start server. Check logs:" >&2
  cat "${SCRIPT_DIR}/server.log" >&2
  exit 1
fi
