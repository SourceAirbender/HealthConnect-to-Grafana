#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f ".env" ]]; then
  echo "Error: .env file not found in $SCRIPT_DIR" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source .env
set +a

"$SCRIPT_DIR/fetch_health_connect.sh"

if [[ "${TARGET_MODE:-local}" == "local" && "${RUN_IMPORT_AFTER_FETCH:-true}" == "true" ]]; then
  VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/venv}"
  IMPORTER_SCRIPT="${IMPORTER_SCRIPT:-$SCRIPT_DIR/health_data_importer.py}"

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "Error: Python venv not found at $VENV_DIR" >&2
    exit 1
  fi

  "$VENV_DIR/bin/python" "$IMPORTER_SCRIPT"
fi

if [[ "${TARGET_MODE:-local}" == "scp" && "${RUN_REMOTE_IMPORT_AFTER_SCP:-false}" == "true" ]]; then
  SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY is required}"
  REMOTE_SSH_HOST="${REMOTE_SSH_HOST:?REMOTE_SSH_HOST is required}"
  REMOTE_IMPORT_COMMAND="${REMOTE_IMPORT_COMMAND:?REMOTE_IMPORT_COMMAND is required}"

  ssh -i "$SSH_PRIVATE_KEY" "$REMOTE_SSH_HOST" "$REMOTE_IMPORT_COMMAND"
fi
