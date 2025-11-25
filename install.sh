#!/usr/bin/env bash
set -euo pipefail

echo "=== SQL Health Data Importer installer ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f ".env" ]]; then
  echo "Error: .env file not found in $SCRIPT_DIR"
  echo "Create a .env file with your PostgreSQL and importer settings first."
  exit 1
fi

echo "Loading configuration from .env..."
set -a
# shellcheck source=/dev/null
source .env
set +a

# ----- Derived/default settings for service + timer -----

PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/venv}"
IMPORTER_SCRIPT="${IMPORTER_SCRIPT:-$PROJECT_ROOT/health_data_importer.py}"

SERVICE_NAME="${SERVICE_NAME:-sql-health-data-importer}"
TIMER_NAME="${TIMER_NAME:-$SERVICE_NAME}"

SERVICE_USER="${SERVICE_USER:-$(whoami)}"
SERVICE_DESCRIPTION="${SERVICE_DESCRIPTION:-SQL Health Data Importer}"
TIMER_DESCRIPTION="${TIMER_DESCRIPTION:-Run SQL Health Data Importer on a schedule}"

ONCALENDAR="${ONCALENDAR:-*-*-* 00:10:00}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

SERVICE_LOG_FILE="${SERVICE_LOG_FILE:-${LOG_FILE:-$PROJECT_ROOT/importer.log}}"

PYTHON_BIN_GLOBAL="${PYTHON_BIN_GLOBAL:-python3}"

echo "Using configuration:"
echo "  PROJECT_ROOT     = $PROJECT_ROOT"
echo "  VENV_DIR         = $VENV_DIR"
echo "  IMPORTER_SCRIPT  = $IMPORTER_SCRIPT"
echo "  SERVICE_NAME     = $SERVICE_NAME"
echo "  TIMER_NAME       = $TIMER_NAME"
echo "  SERVICE_USER     = $SERVICE_USER"
echo "  SERVICE_LOG_FILE = $SERVICE_LOG_FILE"
echo "  ONCALENDAR       = $ONCALENDAR"
echo

# ----- Sanity checks -----

if [[ ! -f "$IMPORTER_SCRIPT" ]]; then
  echo "Error: importer script not found at: $IMPORTER_SCRIPT"
  echo "Set IMPORTER_SCRIPT in .env or rename your script to health_data_importer.py in $PROJECT_ROOT."
  exit 1
fi

if ! command -v "$PYTHON_BIN_GLOBAL" >/dev/null 2>&1; then
  echo "Error: Python interpreter '$PYTHON_BIN_GLOBAL' not found in PATH."
  exit 1
fi

# Make sure required PG vars exist
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

# ----- Virtualenv -----

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment in $VENV_DIR"
  "$PYTHON_BIN_GLOBAL" -m venv "$VENV_DIR"
else
  echo "Virtual environment already exists at $VENV_DIR"
fi

VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

echo "Ensuring pip is available in the virtual environment..."
"$VENV_PYTHON" -m ensurepip --upgrade || true
"$VENV_PIP" install --upgrade pip

# ----- Python deps in venv -----

PYTHON_PACKAGES=(pandas openpyxl psycopg2-binary)
if [[ -n "${EXTRA_PIP_PACKAGES:-}" ]]; then
  # Split EXTRA_PIP_PACKAGES into an array (space-separated)
  read -r -a EXTRA_ARRAY <<< "$EXTRA_PIP_PACKAGES"
  PYTHON_PACKAGES+=("${EXTRA_ARRAY[@]}")
fi

echo "Installing Python packages into venv: ${PYTHON_PACKAGES[*]}"
"$VENV_PIP" install "${PYTHON_PACKAGES[@]}"

# ----- OS deps (apt, if available) -----

APT_PACKAGES=(postgresql-client pgloader)
if command -v apt-get >/dev/null 2>&1; then
  echo "Installing OS packages (if missing): ${APT_PACKAGES[*]}"
  sudo apt-get update
  sudo apt-get install -y "${APT_PACKAGES[@]}"
else
  echo "apt-get not found, skipping OS packages: ${APT_PACKAGES[*]}"
fi

# ----- Test PostgreSQL connection using psycopg2 in venv -----

echo "Testing PostgreSQL connection using psycopg2 and .env settings..."
"$VENV_PYTHON" - << 'EOF'
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
    print("Missing required PostgreSQL env vars for connection:", ", ".join(missing))
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

# ----- systemd service + timer -----

SERVICE_FILE_PATH="$SYSTEMD_DIR/${SERVICE_NAME}.service"
TIMER_FILE_PATH="$SYSTEMD_DIR/${TIMER_NAME}.timer"

echo "Creating systemd service at $SERVICE_FILE_PATH"
SERVICE_FILE_CONTENT="[Unit]
Description=$SERVICE_DESCRIPTION

[Service]
Type=oneshot
ExecStart=$VENV_DIR/bin/python $IMPORTER_SCRIPT
WorkingDirectory=$PROJECT_ROOT
User=$SERVICE_USER
StandardOutput=append:$SERVICE_LOG_FILE
StandardError=append:$SERVICE_LOG_FILE

[Install]
WantedBy=multi-user.target
"

echo "$SERVICE_FILE_CONTENT" | sudo tee "$SERVICE_FILE_PATH" >/dev/null

echo "Creating systemd timer at $TIMER_FILE_PATH"
TIMER_FILE_CONTENT="[Unit]
Description=$TIMER_DESCRIPTION

[Timer]
OnCalendar=$ONCALENDAR
Persistent=true

[Install]
WantedBy=timers.target
"

echo "$TIMER_FILE_CONTENT" | sudo tee "$TIMER_FILE_PATH" >/dev/null

echo "Reloading systemd daemon and enabling timer..."
sudo systemctl daemon-reload
sudo systemctl enable --now "${TIMER_NAME}.timer"

echo
echo "=== Installation complete ==="
echo "Service unit: $SERVICE_FILE_PATH  (${SERVICE_NAME}.service)"
echo "Timer unit:   $TIMER_FILE_PATH  (${TIMER_NAME}.timer)"
echo "It will run on: $ONCALENDAR"
