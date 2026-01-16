#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

APP_CT="nextcloud-server"
BACKUP_ROOT="/export/mariadb/backups/nextcloud"
LOGFILE="/var/log/backuppc/svc-nextcloud-post.log"

# Remove full staging on success (recommended for your model).
# Set to 0 if you ever want to keep artifacts on the host after success.
CLEANUP_ALL_ON_SUCCESS=1

# BackupPC sets xferOK for post commands. If unset, treat as failure.
XFER_OK="${xferOK:-0}"

# ---- Logging setup ----
mkdir -p -- "$(dirname -- "$LOGFILE")"
exec >>"$LOGFILE" 2>&1

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

log "==== POST backup start ===="
log "[INFO] BackupPC xferOK=${XFER_OK}"

PHASE="init"
FAILED=0
FAIL_RC=0
FAIL_MSG=""

# ---- Robust directory removal (remove directory itself) ----
safe_remove_dir() {
  local dir="$1"

  # Guardrails
  if [[ -z "${dir}" || "${dir}" == "/" || "${dir}" == "." ]]; then
    log "[ERROR] Refusing to remove unsafe dir='${dir}'"
    return 2
  fi

  # If it doesn't exist, treat as OK (idempotent)
  if [[ ! -e "${dir}" ]]; then
    log "[INFO] Directory does not exist (nothing to remove): ${dir}"
    return 0
  fi

  if [[ ! -d "${dir}" ]]; then
    log "[ERROR] Path exists but is not a directory: ${dir}"
    return 2
  fi

  log "[INFO] Removing directory: ${dir}"

  # Make subdirectories deletable (this is what bit you with cadir)
  find "${dir}" -xdev -mindepth 1 -type d -exec chmod u+wx {} + || true

  # Remove the directory itself
  rm -rf --one-file-system -- "${dir:?}"
}

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

  # Always remove temporary config directory (it is staging-only).
  PHASE="cleanup_remove_config"
  if ! safe_remove_dir "${BACKUP_ROOT}/config"; then
    log "[ERROR] cleanup: failed to remove temporary config directory"
    if [[ "$FAILED" -eq 0 ]]; then
      FAILED=1
      FAIL_RC=91
      FAIL_MSG="cleanup failed: could not remove temporary config directory"
    fi
  fi

  log "[INFO] Cleanup finished"
}

on_exit() {
  local rc=$?

  # Always try to write finished_at (best effort)
  mkdir -p -- "${BACKUP_ROOT}/meta" || true
  date -Is > "${BACKUP_ROOT}/meta/finished_at" || true

  # Always run cleanup (must restore service state & remove config staging)
  cleanup

  # If the script itself failed, fail the backup and keep artifacts for debugging (except config/).
  if [[ "$FAILED" -ne 0 ]]; then
    printf 'failed\n' > "${BACKUP_ROOT}/meta/status" 2>/dev/null || true
    printf '%s\n' "${FAIL_MSG:-unknown error}" > "${BACKUP_ROOT}/meta/error" 2>/dev/null || true
    log "[ERROR] POST backup failed: ${FAIL_MSG:-unknown error}"
    log "==== POST backup failed ===="
    exit "${FAIL_RC:-1}"
  fi

  # Script checks passed; now enforce BackupPC transfer success
  if [[ "${XFER_OK}" -ne 1 ]]; then
    # Transfer failed: fail job so GUI shows failure; keep artifacts for debugging (except config/).
    printf 'failed\n' > "${BACKUP_ROOT}/meta/status" 2>/dev/null || true
    printf 'xferOK=%s: BackupPC transfer failed; keeping artifacts for debugging\n' "${XFER_OK}" \
      > "${BACKUP_ROOT}/meta/error" 2>/dev/null || true
    log "[ERROR] BackupPC transfer failed (xferOK=${XFER_OK}); keeping artifacts (except config/) for debugging"
    log "==== POST backup failed (xfer) ===="
    exit 100
  fi

  # All good: checks ok and transfer ok
  printf 'ok\n' > "${BACKUP_ROOT}/meta/status" 2>/dev/null || true
  log "[INFO] All checks OK and BackupPC transfer OK (xferOK=1)"

  if [[ "${CLEANUP_ALL_ON_SUCCESS}" -eq 1 ]]; then
    PHASE="cleanup_remove_all"
    log "[INFO] Removing staging directory (success policy): ${BACKUP_ROOT}"
    # Best effort: if this fails, mark as failure (admins should notice)
    if ! safe_remove_dir "${BACKUP_ROOT}"; then
      log "[ERROR] Failed to remove BACKUP_ROOT on success: ${BACKUP_ROOT}"
      exit 101
    fi
  else
    log "[INFO] Success policy: leaving staging directory on host: ${BACKUP_ROOT}"
  fi

  log "==== POST backup completed successfully ===="
  exit 0
}

trap on_err ERR
trap on_exit EXIT

# ---- Main flow ----

PHASE="maintenance_off"
log "[INFO] Disabling maintenance mode"
incus exec "$APP_CT" -- occ maintenance:mode --off

PHASE="db_dump_check"
log "[INFO] Verifying database dump integrity"
DUMP="${BACKUP_ROOT}/db/mariadb.sql.zst"

if [[ ! -s "$DUMP" ]]; then
  fail 10 "DB dump missing or empty: $DUMP"
fi

# True integrity check (no SIGPIPE problems)
if ! zstd -t --quiet "$DUMP"; then
  fail 11 "DB dump failed zstd integrity test (corrupt or unreadable): $DUMP"
  #log "[ERROR] zstd test failed. Dump file details:"
  #ls -l "$DUMP" || true
  # show first bytes for "wrong file" class of bugs, but keep it minimal
  #head -c 64 "$DUMP" | hexdump -C || true
  #fail 11 "DB dump failed zstd integrity test: $DUMP"
fi
log "[INFO] Database dump OK"

# Additional semantic check (optional). Keep disabled unless you want it.
# PHASE="db_dump_content_check"
# if ! zstd -dc "$DUMP" | head -n 1 | grep -Eq '^(--|/\*|CREATE|SET)'; then
#   log "[ERROR] DB dump does not look like SQL: $DUMP"
#   exit 11
# fi

PHASE="done"
log "[INFO] Post script main flow done; exit handler will finalize based on xferOK and internal status"
