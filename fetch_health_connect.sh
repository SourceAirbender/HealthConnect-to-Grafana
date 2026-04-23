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

FETCH_LOG_FILE="${FETCH_LOG_FILE:-${LOG_FILE:-$SCRIPT_DIR/health_connect_fetch.log}}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.work}"
TMP_DIR="$(mktemp -d "${WORK_DIR%/}/extract.XXXXXX")"
DOWNLOADED_ZIP="${WORK_DIR%/}/Health Connect.zip"

mkdir -p "$WORK_DIR"

log() {
  local log_dir
  log_dir="$(dirname "$FETCH_LOG_FILE")"
  mkdir -p "$log_dir"
  printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$FETCH_LOG_FILE"
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CLOUD_BACKEND="${CLOUD_BACKEND:-rclone}"
ZIP_RELATIVE_PATH="${ZIP_RELATIVE_PATH:-Health Connect.zip}"
TARGET_MODE="${TARGET_MODE:-local}"

get_zip() {
  case "$CLOUD_BACKEND" in
    rclone)
      RCLONE_REMOTE="${RCLONE_REMOTE:?RCLONE_REMOTE is required when CLOUD_BACKEND=rclone}"

      if [[ "${RCLONE_USE_MOUNT:-false}" == "true" ]]; then
        MOUNT_DIR="${MOUNT_DIR:?MOUNT_DIR is required when RCLONE_USE_MOUNT=true}"
        ZIP_PATH="${MOUNT_DIR%/}/$ZIP_RELATIVE_PATH"
        [[ -f "$ZIP_PATH" ]] || {
          log "ZIP not found on mounted path: $ZIP_PATH"
          return 1
        }
      else
        log "Copying ZIP from rclone remote..."
        rclone copyto "${RCLONE_REMOTE}:${ZIP_RELATIVE_PATH}" "$DOWNLOADED_ZIP"
        ZIP_PATH="$DOWNLOADED_ZIP"
      fi
      ;;
    raidrive)
      MOUNT_DIR="${MOUNT_DIR:?MOUNT_DIR is required when CLOUD_BACKEND=raidrive}"
      ZIP_PATH="${MOUNT_DIR%/}/$ZIP_RELATIVE_PATH"
      [[ -f "$ZIP_PATH" ]] || {
        log "ZIP not found on RaiDrive mount: $ZIP_PATH"
        return 1
      }
      ;;
    *)
      log "Unsupported CLOUD_BACKEND: $CLOUD_BACKEND"
      return 1
      ;;
  esac

  log "Using ZIP: $ZIP_PATH"
}

deliver_db() {
  local db_file="$1"
  local renamed_db="$TMP_DIR/health_data.db"

  cp -f "$db_file" "$renamed_db"
  log "Renamed DB to health_data.db"

  case "$TARGET_MODE" in
    local)
      LOCAL_DB_DEST="${LOCAL_DB_DEST:?LOCAL_DB_DEST is required when TARGET_MODE=local}"
      install -D -m 0644 "$renamed_db" "$LOCAL_DB_DEST"
      log "Copied DB to local destination: $LOCAL_DB_DEST"
      ;;
    scp)
      SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY is required when TARGET_MODE=scp}"
      REMOTE_SCP_TARGET="${REMOTE_SCP_TARGET:?REMOTE_SCP_TARGET is required when TARGET_MODE=scp}"
      scp -i "$SSH_PRIVATE_KEY" "$renamed_db" "$REMOTE_SCP_TARGET"
      log "Transferred DB via SCP to: $REMOTE_SCP_TARGET"
      ;;
    *)
      log "Unsupported TARGET_MODE: $TARGET_MODE"
      return 1
      ;;
  esac
}

get_zip

log "Extracting ZIP..."
unzip -o "$ZIP_PATH" -d "$TMP_DIR" >/dev/null

DB_FILE="$(find "$TMP_DIR" -type f -name '*.db' | head -n 1 || true)"
if [[ -z "$DB_FILE" ]]; then
  log "No .db file found in ZIP."
  exit 1
fi

deliver_db "$DB_FILE"
log "Health Connect fetch completed successfully."
