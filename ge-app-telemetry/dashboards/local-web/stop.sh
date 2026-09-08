#!/usr/bin/env bash
#
# stop.sh - Stop running local Google Antigravity telemetry dashboard server.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="${SCRIPT_DIR}/server.pid"

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}")"
  if kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" || true
    echo "Stopped dashboard server (PID ${PID})."
  else
    echo "Process ${PID} is not running."
  fi
  rm -f "${PID_FILE}"
else
  # Fallback to pkill node server.mjs
  pkill -f "node ${SCRIPT_DIR}/server.mjs" 2>/dev/null || true
  echo "Dashboard server stopped."
fi
