#!/usr/bin/env bash
# =============================================================================
# Nextcloud Service Backup — Hosted via BackupPC
#
# Pre hook for BackupPC *service backups* integrating
# Incus container-based services Nextcloud and MariaDB with BackupPC.
#
# Key paths:
#   • Staging (scratch on fast storage): /export/mariadb/backuppc/services/<svc>
#   • BackupPC view (bind mount):       /srv/backuppc/services/<svc>
#
# Preconditions:
#   • The user "backuppc" must be allowed to bind mount and unmount
#     the service staging directory for BackupPC to treat it as a
#     distinct backup source.
#
#   • Sudoers (example drop-in under /etc/sudoers.d/backuppc-svc):
#     backuppc ALL = NOPASSWD: /usr/bin/mount --bind /export/mariadb/backuppc/services /srv/backuppc/services
#     backuppc ALL = NOPASSWD: /usr/bin/umount /srv/backuppc/services
#
#   • Required directories must exist prior to backup:
#       sudo mkdir -p /export/mariadb/backuppc/services
#       sudo chown -R backuppc:backuppc /export/mariadb/backuppc
#
#       sudo mkdir -p /srv/backuppc/services
#       sudo chown -R backuppc:backuppc /srv/backuppc
#
#   • This script is invoked by BackupPC as a pre user command
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

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

fail() {
  local rc="$1"; shift
  local msg="$*"
  FAILED=1
  FAIL_RC="$rc"
  FAIL_MSG="phase=${PHASE} rc=${rc} msg=${msg}"
  log "[ERROR] ${FAIL_MSG}"
  exit "$rc"
}

# BIND MOUNT VERIFICATION AND CREATION
# ------------------------------------
# This function ensures DEST is bind-mounted from exactly SOURCE.
#
# How it works:
#   findmnt shows bind mounts to subdirectories as: device[/subpath]
#   We construct this string from SOURCE and compare against DEST.
#
# What it catches:
#   - DEST mounted from wrong directory
#   - DEST mounted from wrong filesystem
#   - DEST is a regular mount, not a bind mount (for subdirectory sources)
#
# Exit codes:
#   0  - Bind mount correctly in place (existing or newly created)
#   20 - Mount verification failed

ensure_bind_mount() {
  local src="${1:-}" dst="${2:-}"

  # Validate parameters
  if [[ -z "$src" || -z "$dst" ]]; then
    log "[ERROR] ensure_bind_mount requires source and destination parameters"
    exit 20
  fi

  # Create directories if needed
  if ! mkdir -p -- "$src" "$dst"; then
    log "[ERROR] Failed to create directories: $src and/or $dst"
    exit 20
  fi

  # Resolve symlinks for consistent comparison
  local src_resolved="" dst_resolved=""
  src_resolved=$(realpath "$src" 2>/dev/null) || true
  dst_resolved=$(realpath "$dst" 2>/dev/null) || true

  if [[ -z "$src_resolved" || ! -d "$src_resolved" ]]; then
    log "[ERROR] Source not accessible: $src"
    exit 20
  fi

  if [[ -z "$dst_resolved" || ! -d "$dst_resolved" ]]; then
    log "[ERROR] Destination not accessible: $dst"
    exit 20
  fi

  # Check if DEST is currently mounted
  local actual=""
  actual=$(findmnt -n -o SOURCE --mountpoint "$dst_resolved" 2>/dev/null) || true

  if [[ -z "$actual" ]]; then
    # Not mounted — create the bind mount
    log "[INFO] Creating bind mount: $src -> $dst"
    if ! sudo /usr/bin/mount --bind "$src" "$dst"; then
      log "[ERROR] Failed to create bind mount: $src -> $dst"
      exit 20
    fi
    log "[INFO] Bind mount created successfully"
    return 0
  fi

  # DEST is mounted — verify it's from exactly SOURCE
  # Walk up SOURCE to find its actual mount point
  local path="$src_resolved"
  local src_device="" src_mountpoint=""
  while [[ -n "$path" ]]; do
    src_device=$(findmnt -n -o SOURCE --mountpoint "$path" 2>/dev/null) || true
    if [[ -n "$src_device" ]]; then
      src_mountpoint="$path"
      break
    fi
    path="${path%/*}"
  done

  if [[ -z "$src_device" ]]; then
    log "[ERROR] Could not determine mount point for source: $src"
    log "[ERROR] Is the underlying filesystem mounted?"
    exit 20
  fi

  # Calculate relative path and build expected SOURCE string
  local relative="${src_resolved#$src_mountpoint}"
  local expected=""
  if [[ -n "$relative" ]]; then
    expected="${src_device}[${relative}]"
  else
    expected="$src_device"
  fi

  # Compare
  if [[ "$actual" == "$expected" ]]; then
    log "[INFO] Bind mount already present: $src -> $dst"
    return 0
  fi

  # Mismatch — report details and fail
  log "[ERROR] $dst is already a mountpoint, but not our expected bind mount."
  log "[ERROR] expected source: $expected"
  log "[ERROR] actual source:   $actual"
  log "[ERROR] findmnt output:"
  log "[ERROR]   $(findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS --target "$dst_resolved" 2>/dev/null || echo 'n/a')"
  exit 20
}

### Enterprise-ish directory cleanup function (wipe contents, keep dir) ###
safe_wipe_dir_contents() {
  local dir="$1"

  if [[ -z "${dir}" || "${dir}" == "/" || "${dir}" == "." ]]; then
    fail 30 "Refusing to wipe unsafe dir='${dir}'"
  fi
  if [[ ! -d "${dir}" ]]; then
    fail 31 "Directory not found: ${dir}"
  fi

  log "[INFO] Preparing to wipe contents of: ${dir}"

  # Make subdirectories deletable (owner needs +w +x on dirs)
  find "${dir}" -xdev -mindepth 1 -type d -exec chmod u+wx {} + || true

  # Remove everything under it (including dotfiles via dotglob)
  local olddotglob oldnullglob
  # Explicitly allow the non-zero exit, as shopt additionally returns exit status = 1
  # if option is disabled (on a normal system dotglob is usually disabled)
  olddotglob=$(shopt -p dotglob || true); oldnullglob=$(shopt -p nullglob || true)
  shopt -s dotglob nullglob
  rm -rf --one-file-system -- "${dir:?}/"*
  eval "$olddotglob"; eval "$oldnullglob"
}

### ERROR AND CLEANUP HANDLERS ###
on_err() {
  local rc=$?
  if [[ "$FAILED" -eq 0 ]]; then
    FAILED=1
    FAIL_RC="$rc"
    FAIL_MSG="phase=${PHASE} rc=${rc} line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}"
    log "[ERROR] ${FAIL_MSG}"
  else
    log "[ERROR] additional error: phase=${PHASE} rc=${rc} line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}"
  fi
  return "$rc"
}

cleanup() {
  log "[INFO] Cleanup triggered"

  # Always try to disable maintenance mode (pre script must not leave service in maintenance)
  if [[ -n "${APP_CT:-}" ]]; then
    if ! incus exec "$APP_CT" -- occ maintenance:mode --off; then
      log "[ERROR] cleanup: failed to disable maintenance mode (container=${APP_CT})"
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
    if [[ "$FAILED" -eq 0 ]]; then
      FAILED=1
      FAIL_RC=91
      FAIL_MSG="cleanup failed: APP_CT not set"
    fi
  fi

  log "[INFO] Cleanup finished"
}

on_exit() {
  local rc=$?

  cleanup

  if [[ "$FAILED" -ne 0 ]]; then
    log "[ERROR] Pre-backup failed: ${FAIL_MSG:-unknown error}"
    log "==== PRE backup failed ===="
    exit "${FAIL_RC:-1}"
  fi

  log "==== PRE backup completed successfully ===="
  exit "$rc"
}

trap on_err ERR
trap on_exit EXIT

### SETUP ###
if [[ ! -d "$(dirname "$LOGFILE")" ]]; then
  echo "[ERROR] BackupPC log/lock directory '$(dirname "$LOGFILE")' not found. Has BackupPC been installed? Aborting." >&2
  exit 1
fi

exec >>"$LOGFILE" 2>&1
log "==== PRE backup start ===="

# Lock to avoid overlapping runs
exec 9>"$LOCKFILE"
flock -n 9 || fail 2 "Another backup is running (lock=$LOCKFILE)"

PHASE="db_ping"
log "Checking database availability"
if ! mariadb-admin ping -h "$DB_HOST" --silent; then
  fail 3 "Database host $DB_HOST not reachable"
fi

# Prepare directory layout
PHASE="prepare_dirs"
mkdir -p -- "${STAGING_DIR}"/{db,app,meta,config,app-list,package-list,systemd-list}

# Record run metadata early
PHASE="meta_start"
RUN_ID="$(date -Is | tr ':' '-')"
printf '%s\n' "$RUN_ID" > "${STAGING_DIR}/meta/run_id"
date -Is > "${STAGING_DIR}/meta/started_at"

### 1. Ensure bind mount exists for BackupPC view ###
PHASE="bind_mount_prepare"
ensure_bind_mount "$STAGING_ROOT" "$VIEW_ROOT"

### 2. Enable maintenance mode ###
PHASE="maintenance_on"
log "Enabling maintenance mode"
incus exec "$APP_CT" -- occ maintenance:mode --on

### 3. Dump MariaDB ###
PHASE="db_dump"
log "Dumping database"
DB_FILE="${STAGING_DIR}/db/mariadb.sql.zst"

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
log "Backing up container configuration (/etc)"
CONFIG_DIR="${STAGING_DIR}/config"
# Clean old extracted folder before extracting (robust against non-writable dirs)
safe_wipe_dir_contents "$CONFIG_DIR"
incus exec "$APP_CT" -- tar cf - -C / etc | tar xf - -C "$CONFIG_DIR"

### 5. Backup Nextcloud app list ###
PHASE="nc_app_list_dump"
log "Backing up Nextcloud app list"
APP_LIST_FILE="${STAGING_DIR}/app-list/apps.txt"
incus exec "$APP_CT" -- occ app:list > "$APP_LIST_FILE"

### 6. Capture Nextcloud state ###
PHASE="nc_state_dump"
log "Capturing Nextcloud state"
incus exec "$APP_CT" -- occ status > "${STAGING_DIR}/app/occ-status.txt"

### 7. Capture Manjaro package lists ###
PHASE="package_list_dump"
log "Capturing Manjaro package lists"
incus exec "$APP_CT" -- pacman -Qqen > "${STAGING_DIR}/package-list/pkglist-repo.txt"
incus exec "$APP_CT" -- pacman -Qqem > "${STAGING_DIR}/package-list/pkglist-aur.txt"
incus exec "$APP_CT" -- pacman -Qe   > "${STAGING_DIR}/package-list/pkg-versions.txt"

### 8. Capture Systemd service list ###
PHASE="systemd_service_dump"
log "Capturing Systemd enabled services"
incus exec "$APP_CT" -- systemctl list-unit-files --state=enabled > "${STAGING_DIR}/systemd-list/systemd-enabled.txt"

# Pre script ends; EXIT trap will disable maintenance mode.
PHASE="done"
log "Pre script main flow done"
