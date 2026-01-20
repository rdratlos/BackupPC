#!/usr/bin/env bash
#
# backuppc-mariadb-core-pre.sh
#
# Stages MariaDB "core metadata" (NOT part of /export/mariadb datadir itself)
# into /export/mariadb/backuppc/core/ so BackupPC can grab a self-contained set.
#
# Intended to run on the HOST (has /export/mariadb mounted and can run `incus`).
#
set -euo pipefail

CT_NAME="${CT_NAME:-mariadb}"
MYSQL_USER="mysql"
MYSQL_UID="100965"
MYSQL_GID="100965"

# Container paths (because /export/mariadb is mounted as /var/lib/mysql in container)
CT_CORE="/var/lib/mysql/backuppc/core"

# Host path (LV mount)
ROOT="/export/mariadb"
CORE="${ROOT}/backuppc/core"

# Safety: don't touch service backups
SERVICES="${ROOT}/backuppc/services"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

need incus
need mkdir
need rm
need tar
need awk
need sed

log "Preparing core staging area at: ${CORE}"
mkdir -p "${CORE}"/{etc,my,meta,notes,physical}

# Guardrail: never delete services backups
if [[ -d "${SERVICES}" ]]; then
  log "Service backup folder exists (will not touch): ${SERVICES}"
fi

# 1) Ensure MariaDB is up (otherwise stop early; a core backup without metadata is risky)
if ! incus exec "${CT_NAME}" -- systemctl is-active --quiet mariadb.service; then
  log "ERROR: mariadb.service is not active in container ${CT_NAME}."
  exit 1
fi

# 2) Force a clean binlog boundary right before BackupPC snapshot
#    This closes the current binlog so files are stable on disk.
log "Flushing binary logs (clean boundary for backup) ..."
incus exec "${CT_NAME}" -- /usr/bin/mariadb -e "FLUSH BINARY LOGS;"

# -----------------------------------------------------------------------------
# Physical backup (mariabackup) - streamed + compressed + metadata captured
# -----------------------------------------------------------------------------

log "Preparing mariabackup physical snapshot ..."

# Ensure physical dir exists (on LV, from inside container path)
PHYS_DIR="${CORE}/physical"
mkdir -p "${PHYS_DIR}"
CT_PHYS_DIR="${CT_CORE}/physical"

# Fixed artifact names (pool-friendly)
OUT_CUR="${PHYS_DIR}/current.xbstream.zst"
OUT_TMP="${PHYS_DIR}/current.xbstream.zst.tmp"

SHA_CUR="${PHYS_DIR}/current.xbstream.zst.sha256"
SHA_TMP="${PHYS_DIR}/current.xbstream.zst.sha256.tmp"

SIZES_CUR="${PHYS_DIR}/current.sizes.txt"
SIZES_TMP="${PHYS_DIR}/current.sizes.txt.tmp"

META_CUR_HOST="${PHYS_DIR}/current.meta"
META_TMP_HOST="${PHYS_DIR}/current.meta.tmp"

# Container view of meta dirs
META_TMP_CT="${CT_PHYS_DIR}/current.meta.tmp"

# Socket path inside container (adjust if your image differs)
DB_SOCKET="/run/mysqld/mysqld.sock"

# Ensure meta dirs are writable by container mysql uid (100965 on host)
log "Preparing physical output folders (sudo wrapper) ..."
sudo /usr/local/sbin/backuppc-mariadb-mkphysdir.sh

# Clean up any leftovers from interrupted runs
rm -f "${OUT_TMP}" "${SHA_TMP}" "${SIZES_TMP}"
rm -rf "${META_TMP_HOST}"
mkdir -p "${META_TMP_HOST}"
# Re-apply ownership after recreating META_TMP_HOST
sudo /usr/local/sbin/backuppc-mariadb-mkphysdir.sh

# Sanity checks inside container
log "Checking mariadb.service + mariadb-backup availability in container ..."
incus exec "${CT_NAME}" -- systemctl is-active --quiet mariadb.service

incus exec "${CT_NAME}" -- bash -lc 'command -v mariadb-backup >/dev/null 2>&1' || {
  log "ERROR: mariadb-backup not found in container. Install package (often mariadb-backup)."
  exit 1
}

# Optional but recommended: ensure we can see the socket
incus exec "${CT_NAME}" -- bash -lc "[[ -S '${DB_SOCKET}' ]]" || {
  log "ERROR: MariaDB socket not found at ${DB_SOCKET} inside container. Adjust DB_SOCKET."
  exit 1
}

# Authoritative binlog boundary right before the snapshot
log "Creating authoritative binlog boundary (FLUSH BINARY LOGS) ..."
incus exec "${CT_NAME}" -- /usr/bin/mariadb --socket="${DB_SOCKET}" -e "FLUSH BINARY LOGS;"

# Run mariadb-backup streaming to a single compressed file on the host.
# Metadata is written by mariadb-backup into META_TMP_CT (must be mysql-writable).
# --extra-lsndir ensures metadata files are written alongside the stream.
#
# Auth note:
# - If root unix_socket auth works, --user=root + --socket is enough.
# - If not, add: --defaults-extra-file=/root/.my.cnf (inside container).
#
log "Running mariadb-backup stream -> zstd -> ${OUT_CUR} (via tmp) ..."
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
mariadb-backup \
  --backup \
  --stream=xbstream \
  --extra-lsndir='${META_TMP_CT}' \
  --user=root \
  --socket='${DB_SOCKET}' \
| zstd -19 -T0
" > "${OUT_TMP}"

# Basic integrity & provenance
log "Writing sha256 checksum ..."
sha256sum "${OUT_TMP}" > "${SHA_TMP}"

# Helpful: capture file sizes (tmp)
du -sh "${OUT_TMP}" "${META_TMP_HOST}" > "${SIZES_TMP}" || true

# Sanity: ensure metadata exists
if [[ ! -f "${META_TMP_HOST}/xtrabackup_checkpoints" ]]; then
  log "ERROR: mariadb-backup metadata missing (xtrabackup_checkpoints not found)."
  exit 1
fi

# Publish atomically:
# - keep last meta as .old (optional)
# - move tmp meta to current
# - move tmp stream + sha to current
rm -rf "${META_CUR_HOST}.old" || true
if [[ -d "${META_CUR_HOST}" ]]; then
  mv -f "${META_CUR_HOST}" "${META_CUR_HOST}.old" || true
fi
mv -f "${META_TMP_HOST}" "${META_CUR_HOST}"

mv -f "${OUT_TMP}" "${OUT_CUR}"
mv -f "${SHA_TMP}" "${SHA_CUR}"
mv -f "${SIZES_TMP}" "${SIZES_CUR}" 2>/dev/null || true

log "mariadb-backup snapshot published:"
log "  ${OUT_CUR}"
log "  ${META_CUR_HOST}"
log "  ${SHA_CUR}"
# 3) Export grants/users into the datadir (on the LV), then copy into core area
#    (This avoids ever needing privileged network DB accounts.)
log "Exporting grants/users via /usr/local/sbin/export-mariadb-grants.sh ..."
incus exec "${CT_NAME}" -- /usr/local/sbin/export-mariadb-grants.sh

# The exporter writes /var/lib/mysql/grants.sql (=> ${ROOT}/grants.sql on host)
if [[ -f "${ROOT}/grants.sql" ]]; then
  cp -a "${ROOT}/grants.sql" "${CORE}/my/grants.sql"
else
  log "ERROR: Expected grants.sql not found at ${ROOT}/grants.sql"
  exit 1
fi

# 4) Capture MariaDB config from inside container (/etc/my.cnf.d)
#    Using incus file pull ensures we get the container's effective config.
log "Capturing /etc/my.cnf.d from container ..."
rm -rf "${CORE}/etc/my.cnf.d"
mkdir -p "${CORE}/etc"
incus file pull -r "${CT_NAME}/etc/my.cnf.d" "${CORE}/etc/"

# 5) Capture systemd unit/timer for binlog flush (host or container version)
#    (Optional but helpful for rebuilds and audits.)
log "Capturing systemd unit/timer if present ..."
mkdir -p "${CORE}/etc/systemd"
# These may or may not exist; ignore if absent
incus exec "${CT_NAME}" -- bash -lc '
set -euo pipefail
for f in /etc/systemd/system/*flush*binlog*.* /etc/systemd/system/*binary*log*.*; do
  [[ -e "$f" ]] && echo "$f"
done
' > "${CORE}/meta/systemd-files.list" || true

while read -r f; do
  [[ -z "$f" ]] && continue
  # Map absolute path into CORE/etc/systemd/...
  rel="${f#/}"
  dst="${CORE}/etc/systemd/${rel//\//_}"
  incus file pull "${CT_NAME}${f}" "${dst}" || true
done < "${CORE}/meta/systemd-files.list"

# 6) Capture a small “state bundle” for restore decisions
#    (Binlog position, binlog list, important variables)
log "Capturing MariaDB metadata (master status, binlog list, key variables) ..."
incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "SHOW MASTER STATUS\G" \
  > "${CORE}/meta/show-master-status.txt" || true

incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "SHOW BINARY LOGS;" \
  > "${CORE}/meta/show-binary-logs.txt" || true

incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "
SHOW GLOBAL VARIABLES WHERE Variable_name IN
('version','log_bin','log_bin_basename','binlog_format','binlog_expire_logs_seconds','expire_logs_days','max_binlog_size');
" > "${CORE}/meta/show-variables.txt" || true

# 7) Stamp the run
{
  echo "timestamp=$(date -Iseconds)"
  echo "container=${CT_NAME}"
  echo "host_root=${ROOT}"
} > "${CORE}/meta/stage-info.txt"

log "Pre-backup staging complete."
log "BackupPC should back up ${ROOT} and exclude ${SERVICES}."
