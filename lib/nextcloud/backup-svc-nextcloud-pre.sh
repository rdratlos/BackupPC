#!/usr/bin/env bash
# =============================================================================
# Nextcloud Service Backup — Hosted via BackupPC
#
# This script is part of the *service backup strategy* integrating
# container-based Nextcloud and MariaDB with BackupPC.
#
# Preconditions:
#   • The user "backuppc" must be allowed to bind mount and unmount
#     the service staging directory for BackupPC to treat it as a
#     distinct backup source.
#
#   • The following sudoers rules must be in place (see doc/setup):
#       backuppc ALL = NOPASSWD: /usr/bin/mount --bind /export/mariadb/backuppc/services/ /srv/backuppc/services/
#       backuppc ALL = NOPASSWD: /usr/bin/umount /srv/backuppc/services/
#
#   • Required directories must exist prior to backup:
#       sudo mkdir -p /export/mariadb/backuppc/services
#       sudo chown -R backuppc:backuppc /export/mariadb/backuppc
#
#       sudo mkdir -p /srv/backuppc/services
#       sudo chown -R backuppc:backuppc /srv/backuppc
#
#   • This script is invoked by BackupPC as a pre/post user command
#     with uid=backuppc.
#
# Exit behavior:
#   • On success: exit 0 (BackupPC marks job as success)
#   • On failure: exit > 0 (BackupPC marks job as failure and triggers alerts)
#
# Logging:
#   • Standard output and stderr are logged to a per-host service log.
#
# Note:
#   This script is *not* a general host backup but a staging step for
#   application-consistent service artifacts that BackupPC will ingest.
#
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

### CONFIG ###
APP_CT="nextcloud-server"
DB_HOST="minerva.nepomuc.de"
DB_NAME="nextcloud"
BACKUP_USER="BackupOp"

# --- Service bind-mount configuration ---
SERVICE_NAME="nextcloud"
STAGING_ROOT="/export/mariadb/backuppc/services"
VIEW_ROOT="/srv/backuppc/services"

STAGING_DIR="${STAGING_ROOT}/${SERVICE_NAME}"
VIEW_DIR="${VIEW_ROOT}/${SERVICE_NAME}"

LOCKFILE="/var/log/backuppc/LOCK.svc-nextcloud"
LOGFILE="/var/log/backuppc/svc-nextcloud-pre.log"

# Human-readable phase marker for logs
PHASE="init"

# Track failure state across traps
FAILED=0
FAIL_RC=0
FAIL_MSG=""

### SETUP ###
mkdir -p "STAGING_DIR"/{db,app,meta,config,app-list,package-list,systemd-list}

if [ ! -d "$(dirname "$LOGFILE")" ]; then
    echo "[ERROR]  BackupPC log/lock directory  '$(dirname "$LOGFILE")' not found. Has BackupPC been installed? Aborting."
    exit 1
fi

exec >>"$LOGFILE" 2>&1
echo "==== PRE backup start: $(date -Is) ===="

echo "Checking database availability"
if ! mariadb-admin ping -h "$DB_HOST" --silent; then
  echo "[ERROR]  Database host $DB_HOST not reachable, aborting"
  exit 1
fi

exec 9>"$LOCKFILE"
flock -n 9 || {
  echo "[ERROR]  Another backup is running, aborting."
  exit 1
}

### Service bind mount functions ###
is_mounted() {
  mountpoint -q -- "$1"
}

ensure_bind_mount() {
  local src="$1" dst="$2"

  mkdir -p -- "$src" "$dst"

  if is_mounted "$dst"; then
    # If already mounted, verify it's the mount we expect.
    # (Prevents accidentally backing up the wrong mounted filesystem.)
    local actual_src
    actual_src="$(findmnt -n -o SOURCE --target "$dst" 2>/dev/null || true)"
    if [[ "$actual_src" != "$src" ]]; then
      log "[ERROR] $dst is already a mountpoint, but source differs (expected=$src actual=$actual_src)"
      exit 20
    fi
    log "[INFO] Bind mount already present: $src -> $dst"
    return 0
  fi

  log "[INFO] Creating bind mount: $src -> $dst"
  sudo /usr/bin/mount --bind "$src" "$dst"
}

### Enterprise-ish directory cleanup function ###
safe_wipe_dir_contents() {
  local dir="$1"

  # Guardrails: refuse to run on empty/unsafe targets
  if [[ -z "${dir}" || "${dir}" == "/" || "${dir}" == "." ]]; then
    echo "[ERROR] Refusing to wipe unsafe dir='${dir}'"
    return 2
  fi
  if [[ ! -d "${dir}" ]]; then
    echo "[ERROR] Directory not found: ${dir}"
    return 2
  fi

  echo "[INFO] Preparing to wipe contents of: ${dir}"

  # 1) Make directories deletable: owner needs +w and +x on dirs
  # -mindepth 1 ensures we don't chmod the root dir itself unless you want to.
  # -xdev avoids crossing filesystem boundaries if there are mounts under it.
  # chmod on directories is sufficient; we do not need to chmod files/symlinks.
  find "${dir}" -xdev -mindepth 1 -type d -exec chmod u+wx {} + || true

  # Optional: if you have ACLs that might deny deletion, you can also clear ACLs.
  # (Only enable if ACLs are in play; otherwise keep it simple.)
  # find "${dir}" -xdev -mindepth 1 -type d -exec setfacl -b {} + || true

  # 2) Now wipe everything under it
  rm -rf --one-file-system -- "${dir:?}/"*
}

### ERROR AND CLEANUP HANDLER ###
log() {
  # ISO timestamps are easiest to correlate in centralized logs
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

on_err() {
  local rc=$?
  # If we already captured a failure, don't overwrite it
  if [[ "$FAILED" -eq 0 ]]; then
    FAILED=1
    FAIL_RC="$rc"
    FAIL_MSG="phase=${PHASE} rc=${rc} line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}"
    log "[ERROR] ${FAIL_MSG}"
  else
    log "[ERROR] additional error: phase=${PHASE} rc=${rc} line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}"
  fi
  # Let the script continue to EXIT trap for cleanup
  return "$rc"
}

cleanup() {
  # Your existing cleanup operations go here.
  # IMPORTANT: cleanup must not call "exit" directly.
  log "[INFO] Cleanup triggered"

  # Disable maintenance mode best-effort — but if it fails, that should be visible
  if [[ -n "${APP_CT:-}" ]]; then
    if ! incus exec "$APP_CT" -- occ maintenance:mode --off; then
      log "[ERROR] cleanup: failed to disable maintenance mode (container=${APP_CT})"
      # If there was no earlier failure, mark cleanup failure as failure of the run
      if [[ "$FAILED" -eq 0 ]]; then
        FAILED=1
        FAIL_RC=90
        FAIL_MSG="cleanup failed: could not disable maintenance mode"
      fi
    else
      log "[INFO] Maintenance mode disabled"
    fi
  else
    log "[WARN] cleanup: APP_CT not set, cannot disable maintenance mode"
    # You can decide whether this should fail the run; I'd treat it as failure:
    if [[ "$FAILED" -eq 0 ]]; then
      FAILED=1
      FAIL_RC=91
      FAIL_MSG="cleanup failed: APP_CT not set"
    fi
  fi

  log "[INFO] Cleanup finished"
}

on_exit() {
  local rc=$?  # rc at script end (may be 0 even if we recorded an error)
  # Always attempt cleanup
  cleanup

  # Enforce failure if any phase reported failure (or cleanup marked it)
  if [[ "$FAILED" -ne 0 ]]; then
    log "[ERROR] Pre-backup failed: ${FAIL_MSG:-unknown error}"
    echo "==== PRE backup failed at $(date -Is) ===="
    exit "${FAIL_RC:-1}"
  fi

  # Otherwise exit with original rc (should be 0)
  echo "==== PRE backup completed successfully at $(date -Is) ===="
  exit "$rc"
}

trap on_err ERR
trap on_exit EXIT

### 1. Check and Prepare Bind Mounts for BackupPC ###
PHASE="bind_mount_prepare"
ensure_bind_mount "$STAGING_DIR" "$VIEW_DIR"

### 2. Enable maintenance mode ###
PHASE="maintenance_on"
log "Enabling maintenance mode"
incus exec "$APP_CT" -- occ maintenance:mode --on

### 3. Dump MariaDB ###
PHASE="db_dump"
log "Dumping database"
DB_FILE="STAGING_DIR/db/mariadb.sql.zst"
mariadb-dump \
  --single-transaction \
  --routines \
  --events \
  --triggers \
  -h "$DB_HOST" \
  -u "$BACKUP_USER" \
  "$DB_NAME" \
| zstd -19 -T0 > "$DB_FILE"

### 4. Backup Nextcloud configuration (/etc) ###
PHASE="etc_backup"
log "Backing up container configuration (/etc)..."
CONFIG_DIR="STAGING_DIR/config"
# Clean old extracted folder before extracting (robust against non-writable dirs)
safe_wipe_dir_contents "$CONFIG_DIR"
incus exec "$APP_CT" -- tar cf - -C / etc | tar xf - -C "$CONFIG_DIR"

### 5. Backup Nextcloud app list ###
PHASE="nc_app_list_dump"
log "Backing up Nextcloud app list..."
APP_LIST_FILE="STAGING_DIR/app-list/apps.txt"
incus exec "$APP_CT" -- occ app:list > "$APP_LIST_FILE"

### 6. Capture Nextcloud state ###
PHASE="nc_state_dump"
log "Capturing Nextcloud state..."
incus exec "$APP_CT" -- occ status > "STAGING_DIR/app/occ-status.txt"

### 7. Capture Manjaro package lists ###
PHASE="package_list_dump"
log "Capturing Manjaro package lists..."
incus exec "$APP_CT" -- pacman -Qqen > "STAGING_DIR/package-list/pkglist-repo.txt"
incus exec "$APP_CT" -- pacman -Qqem > "STAGING_DIR/package-list/pkglist-aur.txt"
incus exec "$APP_CT" -- pacman -Qe   > "STAGING_DIR/package-list/pkg-versions.txt"

### 8. Capture Systemd Service lists ###
PHASE="systemd_service_dump"
log "Capturing Systemd service lists..."
incus exec "$APP_CT" -- systemctl list-unit-files --state=enabled > "STAGING_DIR/systemd-list/systemd-enabled.txt"

### 9. Timestamp ###
date -Is > "STAGING_DIR/meta/started_at"
