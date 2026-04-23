#!/usr/bin/env bash
set -euo pipefail

echo "=== Health Connect pipeline installer ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f ".env" ]]; then
  echo "Error: .env file not found in $SCRIPT_DIR"
  echo "Create .env first."
  exit 1
fi

echo "Loading configuration from .env..."
set -a
# shellcheck source=/dev/null
source .env
set +a

PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/venv}"
IMPORTER_SCRIPT="${IMPORTER_SCRIPT:-$PROJECT_ROOT/health_data_importer.py}"
PIPELINE_SCRIPT="${PIPELINE_SCRIPT:-$PROJECT_ROOT/run_pipeline.sh}"
FETCH_SCRIPT="${FETCH_SCRIPT:-$PROJECT_ROOT/fetch_health_connect.sh}"

SERVICE_NAME="${SERVICE_NAME:-health-connect-pipeline}"
TIMER_NAME="${TIMER_NAME:-$SERVICE_NAME}"

SERVICE_USER="${SERVICE_USER:-$(whoami)}"
SERVICE_DESCRIPTION="${SERVICE_DESCRIPTION:-Health Connect Fetch + SQL Importer}"
TIMER_DESCRIPTION="${TIMER_DESCRIPTION:-Run Health Connect pipeline on a schedule}"

ONCALENDAR="${ONCALENDAR:-*-*-* 00:10:00}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_LOG_FILE="${SERVICE_LOG_FILE:-${LOG_FILE:-$PROJECT_ROOT/pipeline.log}}"

PYTHON_BIN_GLOBAL="${PYTHON_BIN_GLOBAL:-python3}"
CLOUD_BACKEND="${CLOUD_BACKEND:-rclone}"

echo "Using configuration:"
echo "  PROJECT_ROOT     = $PROJECT_ROOT"
echo "  VENV_DIR         = $VENV_DIR"
echo "  IMPORTER_SCRIPT  = $IMPORTER_SCRIPT"
echo "  PIPELINE_SCRIPT  = $PIPELINE_SCRIPT"
echo "  FETCH_SCRIPT     = $FETCH_SCRIPT"
echo "  SERVICE_NAME     = $SERVICE_NAME"
echo "  TIMER_NAME       = $TIMER_NAME"
echo "  SERVICE_USER     = $SERVICE_USER"
echo "  SERVICE_LOG_FILE = $SERVICE_LOG_FILE"
echo "  ONCALENDAR       = $ONCALENDAR"
echo "  CLOUD_BACKEND    = $CLOUD_BACKEND"
echo

# Basic checks
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  echo "Error: SERVICE_USER '$SERVICE_USER' does not exist."
  exit 1
fi

for file in "$IMPORTER_SCRIPT" "$PIPELINE_SCRIPT" "$FETCH_SCRIPT"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: required file not found: $file"
    exit 1
  fi
done

if ! command -v "$PYTHON_BIN_GLOBAL" >/dev/null 2>&1; then
  echo "Error: Python interpreter '$PYTHON_BIN_GLOBAL' not found in PATH."
  exit 1
fi

# Make helper scripts executable automatically
chmod +x "$FETCH_SCRIPT"
chmod +x "$PIPELINE_SCRIPT"

# Install OS packages
if command -v apt-get >/dev/null 2>&1; then
  echo "Installing OS packages..."
  sudo apt-get update
  sudo apt-get install -y \
    python3-venv \
    unzip \
    openssh-client \
    curl \
    ca-certificates
else
  echo "apt-get not found, skipping OS package installation."
fi

# Install rclone if needed
if [[ "$CLOUD_BACKEND" == "rclone" ]]; then
  if ! command -v rclone >/dev/null 2>&1; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | sudo bash
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    echo "Error: rclone installation failed or rclone is not in PATH."
    exit 1
  fi

  echo "rclone version:"
  rclone version
  echo
fi

# Create virtual environment
if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment in $VENV_DIR"
  "$PYTHON_BIN_GLOBAL" -m venv "$VENV_DIR"
else
  echo "Virtual environment already exists at $VENV_DIR"
fi

VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "Error: virtualenv python not found at $VENV_PYTHON"
  exit 1
fi

echo "Ensuring pip is available in the virtual environment..."
"$VENV_PYTHON" -m ensurepip --upgrade || true
"$VENV_PIP" install --upgrade pip

echo "Installing Python packages..."
"$VENV_PIP" install psycopg2-binary python-dotenv

if [[ -n "${EXTRA_PIP_PACKAGES:-}" ]]; then
  read -r -a EXTRA_ARRAY <<< "$EXTRA_PIP_PACKAGES"
  if (( ${#EXTRA_ARRAY[@]} > 0 )); then
    "$VENV_PIP" install "${EXTRA_ARRAY[@]}"
  fi
fi

mkdir -p "$PROJECT_ROOT"
mkdir -p "$(dirname "$SERVICE_LOG_FILE")"

# Check local importer env only if importer is supposed to run locally
if [[ "${TARGET_MODE:-local}" == "local" && "${RUN_IMPORT_AFTER_FETCH:-true}" == "true" ]]; then
  REQUIRED_ENV_VARS=(SQLITE_DB_PATH LOG_FILE PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD)
  MISSING=()

  for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      MISSING+=("$var")
    fi
  done

  if (( ${#MISSING[@]} > 0 )); then
    echo "Error: missing required environment variables in .env:"
    for var in "${MISSING[@]}"; do
      echo "  - $var"
    done
    exit 1
  fi

  echo "Testing PostgreSQL connection..."
  "$VENV_PYTHON" - <<'EOF'
import os
import psycopg2
import sys

cfg = {
    "host": os.getenv("PGHOST"),
    "port": os.getenv("PGPORT"),
    "database": os.getenv("PGDATABASE"),
    "user": os.getenv("PGUSER"),
    "password": os.getenv("PGPASSWORD"),
}

missing = [k for k, v in cfg.items() if not v]
if missing:
    print("Missing required PostgreSQL env vars:", ", ".join(missing))
    sys.exit(1)

try:
    conn = psycopg2.connect(**cfg)
    conn.close()
    print("PostgreSQL connection test: OK")
except Exception as e:
    print("PostgreSQL connection test: FAILED")
    print(e)
    sys.exit(1)
EOF
  echo
fi

# Check rclone remote as the same user systemd will use
if [[ "$CLOUD_BACKEND" == "rclone" ]]; then
  if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    echo "Error: RCLONE_REMOTE is not set in .env"
    exit 1
  fi

  echo "Testing rclone remote '${RCLONE_REMOTE}' as user '${SERVICE_USER}'..."
  if ! sudo -u "$SERVICE_USER" rclone lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1; then
    echo
    echo "rclone remote test failed for user: $SERVICE_USER"
    echo "If you configured rclone as root, set SERVICE_USER=\"root\" in .env"
    echo "Or configure rclone for user '$SERVICE_USER' and try again."
    exit 1
  fi
  echo "rclone remote test: OK"
  echo
fi

SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
if [[ -z "$SERVICE_HOME" ]]; then
  echo "Error: could not determine home directory for '$SERVICE_USER'"
  exit 1
fi

SERVICE_FILE_PATH="$SYSTEMD_DIR/${SERVICE_NAME}.service"
TIMER_FILE_PATH="$SYSTEMD_DIR/${TIMER_NAME}.timer"

echo "Creating systemd service at $SERVICE_FILE_PATH"
sudo tee "$SERVICE_FILE_PATH" >/dev/null <<EOF
[Unit]
Description=$SERVICE_DESCRIPTION
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
WorkingDirectory=$PROJECT_ROOT
Environment=HOME=$SERVICE_HOME
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash $PIPELINE_SCRIPT
StandardOutput=append:$SERVICE_LOG_FILE
StandardError=append:$SERVICE_LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

echo "Creating systemd timer at $TIMER_FILE_PATH"
sudo tee "$TIMER_FILE_PATH" >/dev/null <<EOF
[Unit]
Description=$TIMER_DESCRIPTION

[Timer]
OnCalendar=$ONCALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Reloading systemd daemon and enabling timer..."
sudo systemctl daemon-reload
sudo systemctl enable --now "${TIMER_NAME}.timer"

echo
echo "=== Installation complete ==="
echo "Service unit: $SERVICE_FILE_PATH"
echo "Timer unit:   $TIMER_FILE_PATH"
echo "Runs on:      $ONCALENDAR"
echo
echo "Useful checks:"
echo "  sudo systemctl status ${TIMER_NAME}.timer"
echo "  sudo systemctl start ${SERVICE_NAME}.service"
echo "  journalctl -u ${SERVICE_NAME}.service -n 100 --no-pager"
