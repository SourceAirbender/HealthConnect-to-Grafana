#!/usr/bin/env bash
set -euo pipefail

echo "=== SQL Health Data Importer uninstaller ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f ".env" ]]; then
  echo "Loading configuration from .env..."
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
else
  echo ".env not found, falling back to defaults for names/paths."
fi

PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
SERVICE_NAME="${SERVICE_NAME:-sql-health-data-importer}"
TIMER_NAME="${TIMER_NAME:-$SERVICE_NAME}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

SERVICE_FILE_PATH="$SYSTEMD_DIR/${SERVICE_NAME}.service"
TIMER_FILE_PATH="$SYSTEMD_DIR/${TIMER_NAME}.timer"

echo "Using:"
echo "  SERVICE_NAME = $SERVICE_NAME"
echo "  TIMER_NAME   = $TIMER_NAME"
echo "  SYSTEMD_DIR  = $SYSTEMD_DIR"
echo

# Stop and disable timer if it exists
if systemctl list-unit-files | grep -q "^${TIMER_NAME}.timer"; then
  echo "Stopping and disabling timer ${TIMER_NAME}.timer (if active/enabled)..."
  if systemctl is-active --quiet "${TIMER_NAME}.timer"; then
    sudo systemctl stop "${TIMER_NAME}.timer"
  fi
  if systemctl is-enabled --quiet "${TIMER_NAME}.timer"; then
    sudo systemctl disable "${TIMER_NAME}.timer"
  fi
else
  echo "Timer ${TIMER_NAME}.timer not found in systemd unit files."
fi

# Stop and disable service if it exists
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  echo "Stopping and disabling service ${SERVICE_NAME}.service (if active/enabled)..."
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    sudo systemctl stop "${SERVICE_NAME}.service"
  fi
  if systemctl is-enabled --quiet "${SERVICE_NAME}.service"; then
    sudo systemctl disable "${SERVICE_NAME}.service"
  fi
else
  echo "Service ${SERVICE_NAME}.service not found in systemd unit files."
fi

# Remove unit files
if [[ -f "$TIMER_FILE_PATH" ]]; then
  echo "Removing timer unit file $TIMER_FILE_PATH"
  sudo rm "$TIMER_FILE_PATH"
fi

if [[ -f "$SERVICE_FILE_PATH" ]]; then
  echo "Removing service unit file $SERVICE_FILE_PATH"
  sudo rm "$SERVICE_FILE_PATH"
fi

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload
sudo systemctl reset-failed "${SERVICE_NAME}.service" || true
sudo systemctl reset-failed "${TIMER_NAME}.timer" || true

echo
echo "=== Uninstall complete ==="
echo "Systemd service and timer have been removed."
echo "Project files and virtualenv (if any) are left untouched at: $PROJECT_ROOT"
