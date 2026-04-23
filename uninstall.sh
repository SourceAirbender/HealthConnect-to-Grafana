#!/usr/bin/env bash
set -euo pipefail

echo "=== Health Connect pipeline uninstaller ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f ".env" ]]; then
  echo "Loading configuration from .env..."
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
else
  echo ".env not found, falling back to defaults."
fi

PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
SERVICE_NAME="${SERVICE_NAME:-health-connect-pipeline}"
TIMER_NAME="${TIMER_NAME:-$SERVICE_NAME}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

SERVICE_FILE_PATH="$SYSTEMD_DIR/${SERVICE_NAME}.service"
TIMER_FILE_PATH="$SYSTEMD_DIR/${TIMER_NAME}.timer"

echo "Using:"
echo "  SERVICE_NAME = $SERVICE_NAME"
echo "  TIMER_NAME   = $TIMER_NAME"
echo "  SYSTEMD_DIR  = $SYSTEMD_DIR"
echo

if systemctl list-unit-files | grep -q "^${TIMER_NAME}\.timer"; then
  echo "Stopping and disabling ${TIMER_NAME}.timer..."
  sudo systemctl stop "${TIMER_NAME}.timer" 2>/dev/null || true
  sudo systemctl disable "${TIMER_NAME}.timer" 2>/dev/null || true
else
  echo "Timer ${TIMER_NAME}.timer not found."
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  echo "Stopping and disabling ${SERVICE_NAME}.service..."
  sudo systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  sudo systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
else
  echo "Service ${SERVICE_NAME}.service not found."
fi

if [[ -f "$TIMER_FILE_PATH" ]]; then
  echo "Removing $TIMER_FILE_PATH"
  sudo rm -f "$TIMER_FILE_PATH"
fi

if [[ -f "$SERVICE_FILE_PATH" ]]; then
  echo "Removing $SERVICE_FILE_PATH"
  sudo rm -f "$SERVICE_FILE_PATH"
fi

echo "Reloading systemd..."
sudo systemctl daemon-reload
sudo systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
sudo systemctl reset-failed "${TIMER_NAME}.timer" 2>/dev/null || true

echo
echo "=== Uninstall complete ==="
echo "Systemd service/timer removed."
echo "Project files, virtualenv, logs, and rclone config were left untouched at: $PROJECT_ROOT"
