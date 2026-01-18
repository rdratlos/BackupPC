#!/usr/bin/env bash
# =============================================================================
# Nextcloud Service Backup — Hosted via BackupPC
#
# Post hook for BackupPC *service backups* integrating
# Incus container-based Nextcloud and MariaDB with BackupPC.
#
# Responsibilities:
#   • Restore service operation (disable maintenance mode)
#   • Validate staged artifacts (e.g., DB dump integrity)
#   • Record meta information (status, error, timestamps, xferOK)
#   • On success: unmount BackupPC view and remove staging
#   • On failure or xferOK!=1: keep bind mount + staging as evidence
#
# Key paths:
#   • Staging (scratch): /export/mariadb/backuppc/services/<svc>
#   • BackupPC view:    /srv/backuppc/services/<svc>
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
#   • This script is invoked by BackupPC as a post user command
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
SERVICE_NAME="nextcloud"
STAGING_ROOT="/export/mariadb/backuppc/services"
VIEW_ROOT="/srv/backuppc/services"

STAGING_DIR="${STAGING_ROOT}/${SERVICE_NAME}"
VIEW_DIR="${VIEW_ROOT}/${SERVICE_NAME}"

LOGFILE="/var/log/backuppc/svc-nextcloud-post.log"

# BackupPC sets xferOK for post commands. If unset, treat as failure.
XFER_OK="${xferOK:-0}"

### LOGGING SETUP ###
mkdir -p -- "$(dirname -- "$LOGFILE")"
exec >>"$LOGFILE" 2>&1

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

PHASE="init"
FAILED=0
FAIL_RC=0
FAIL_MSG=""

META_DIR="${STAGING_DIR}/meta"

fail() {
  local rc="$1"; shift
  local msg="$*"
  FAILED=1
  FAIL_RC="$rc"
  FAIL_MSG="phase=${PHASE} rc=${rc} msg=${msg}"
  log "[ERROR] ${FAIL_MSG}"
  exit "$rc"
}

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

# Remove directory (best-effort permission fix for deletability)
safe_remove_dir() {
  local dir="$1"

  if [[ -z "${dir}" || "${dir}" == "/" || "${dir}" == "." ]]; then
    log "[ERROR] Refusing to remove unsafe dir='${dir}'"
    return 2
  fi

  [[ -e "$dir" ]] || return 0
  [[ -d "$dir" ]] || { log "[ERROR] Path exists but is not a directory: $dir"; return 2; }

  find "$dir" -xdev -mindepth 1 -type d -exec chmod u+wx {} + || true
  rm -rf --one-file-system -- "${dir:?}"
}

# BIND MOUNT CLEANUP
# ------------------
# Unmounts DEST only if it is a direct mount point.
# If DEST is accessible via parent mount, leave it alone (not our responsibility).
# If mount is busy, logs warning and returns success (intentional for failure investigation).
#
# Exit codes:
#   0  - Mount cleaned up OR not a direct mount OR busy (all acceptable states)
remove_bind_mount() {
  local dst="${1:-}"

  if [[ -z "$dst" ]]; then
    log "[ERROR] remove_bind_mount requires destination parameter"
    return 0  # Don't fail the whole post-script for parameter error
  fi

  local dst_resolved=""
  dst_resolved=$(realpath "$dst" 2>/dev/null) || true

  if [[ -z "$dst_resolved" || ! -d "$dst_resolved" ]]; then
    log "[WARN] Destination not accessible: $dst (already cleaned up?)"
    return 0
  fi

  # Check if DEST is itself a mount point
  local actual=""
  actual=$(findmnt -n -o SOURCE --mountpoint "$dst_resolved" 2>/dev/null) || true

  if [[ -z "$actual" ]]; then
    # Not a direct mount point — check if accessible via parent
    local via_parent=""
    via_parent=$(findmnt -n -o SOURCE --target "$dst_resolved" 2>/dev/null) || true

    if [[ -n "$via_parent" ]]; then
      log "[INFO] $dst accessible via parent mount, not a direct mount point — skipping"
    else
      log "[INFO] $dst is not mounted — nothing to unmount"
    fi
    return 0
  fi

  # DEST is a direct mount point — unmount it
  log "[INFO] Unmounting bind mount: $dst"
  if ! sudo /usr/bin/umount "$dst"; then
    log "[WARN] Cannot unmount $dst — mount is busy or in use"
    log "[WARN] This may be intentional (failed backup investigation) or another process"
    log "[WARN] findmnt output:"
    log "[WARN]   $(findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$dst_resolved" 2>/dev/null || echo 'n/a')"
    log "[WARN] Open files:"
    log "[WARN]   $(sudo lsof +f -- "$dst_resolved" 2>/dev/null | head -10 || echo 'n/a')"
    return 0
  fi

  log "[INFO] Bind mount removed successfully"
  return 0
}

write_meta_always() {
  # Best effort; never fail the script just because meta couldn't be written.
  mkdir -p -- "$META_DIR" 2>/dev/null || true
  printf '%s\n' "$XFER_OK" > "${META_DIR}/xferOK" 2>/dev/null || true
  date -Is > "${META_DIR}/finished_at" 2>/dev/null || true
}

write_meta_status() {
  local status="$1"; shift
  local err_msg="$*"

  mkdir -p -- "$META_DIR" 2>/dev/null || true
  printf '%s\n' "$status" > "${META_DIR}/status" 2>/dev/null || true

  if [[ "$status" == "ok" ]]; then
    # Clear stale error (optional)
    : > "${META_DIR}/error" 2>/dev/null || true
  else
    printf '%s\n' "$err_msg" > "${META_DIR}/error" 2>/dev/null || true
  fi
}

cleanup() {
  log "[INFO] Cleanup triggered (phase=${PHASE})"

  # Always attempt to disable maintenance mode.
  PHASE="cleanup_maintenance_off"
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

  # Always remove temporary config snapshot (staging-only, safe to delete even on failure)
  PHASE="cleanup_remove_config"
  if ! safe_remove_dir "${STAGING_DIR}/config"; then
    log "[ERROR] cleanup: failed to remove temporary config directory"
    if [[ "$FAILED" -eq 0 ]]; then
      FAILED=1
      FAIL_RC=91
      FAIL_MSG="cleanup failed: could not remove temporary config directory"
    fi
  fi

  log "[INFO] Cleanup finished"
}

finalize_mount_and_staging() {
  # Policy:
  #   • If FAILED != 0 OR xferOK != 1: keep bind mount + staging for evidence
  #   • If success AND xferOK == 1: unmount view + remove full staging

  if [[ "$FAILED" -ne 0 ]]; then
    log "[WARN] Failure detected; preserving bind mount + staging for evidence: view=${VIEW_DIR} staging=${STAGING_DIR}"
    return 0
  fi

  if [[ "$XFER_OK" -ne 1 ]]; then
    log "[WARN] BackupPC transfer failed (xferOK=${XFER_OK}); preserving bind mount + staging for evidence: view=${VIEW_DIR} staging=${STAGING_DIR}"
    return 0
  fi

  # Success
  PHASE="cleanup_success"
  remove_bind_mount "$VIEW_ROOT"
  if ! safe_remove_dir "$STAGING_DIR"; then
    # This should be visible as a failure in BackupPC GUI
    fail 101 "Failed to remove staging directory on success: ${STAGING_DIR}"
  fi
  # Optional: remove empty view dir
  rmdir "$VIEW_DIR" 2>/dev/null || true
}

on_exit() {
  local rc=$?

  write_meta_always

  cleanup

  if [[ "$FAILED" -ne 0 ]]; then
    write_meta_status "failed" "${FAIL_MSG:-unknown error}"
    log "[ERROR] POST backup failed: ${FAIL_MSG:-unknown error}"
    finalize_mount_and_staging
    log "==== POST backup failed ===="
    exit "${FAIL_RC:-1}"
  fi

  if [[ "$XFER_OK" -ne 1 ]]; then
    write_meta_status "failed" "xferOK=${XFER_OK}: BackupPC transfer failed; preserving evidence"
    log "[ERROR] BackupPC transfer failed (xferOK=${XFER_OK}); preserving evidence"
    finalize_mount_and_staging
    log "==== POST backup failed (xfer) ===="
    exit 100
  fi

  write_meta_status "ok"
  log "[INFO] All checks OK and BackupPC transfer OK (xferOK=1)"

  finalize_mount_and_staging

  log "==== POST backup completed successfully ===="
  exit 0
}

trap on_err ERR
trap on_exit EXIT

log "==== POST backup start ===="
log "[INFO] BackupPC xferOK=${XFER_OK}"

### MAIN FLOW ###

PHASE="maintenance_off"
log "[INFO] Disabling maintenance mode"
incus exec "$APP_CT" -- occ maintenance:mode --off

PHASE="db_dump_check"
log "[INFO] Verifying database dump integrity"
DUMP="${STAGING_DIR}/db/mariadb.sql.zst"

if [[ ! -s "$DUMP" ]]; then
  fail 10 "DB dump missing or empty: $DUMP"
fi

if ! zstd -t --quiet "$DUMP"; then
  fail 11 "DB dump failed zstd integrity test (corrupt or unreadable): $DUMP"
fi

log "[INFO] Database dump OK"

PHASE="done"
log "[INFO] Post script main flow done; exit handler will finalize based on xferOK and internal status"
