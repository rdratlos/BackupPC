#!/usr/bin/env bash
#
# backuppc-mariadb-core-pre.sh
#
# Create MariaDB "core" backup artifacts in a temp directory inside the datadir
# mount (/var/lib/mysql/.tmp_backuppc), then copy them to
# /export/mariadb/backuppc/core for BackupPC to pick up.
#
# Intended to run on the HOST as user backuppc (has /export/mariadb mounted and can run `incus`).
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

# Socket path inside container (adjust if your image differs)
DB_SOCKET="/run/mysqld/mysqld.sock"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }; }

need incus
need rsync
need mkdir
need rm
need tar
need sha256sum
need date

# -----------------------------------------------------------------------------
# Paths for stable artifacts under BackupPC core (pool-friendly)
# -----------------------------------------------------------------------------
PHYS_DIR="${CORE}/physical"
mkdir -p "${PHYS_DIR}"

OUT_CUR="${PHYS_DIR}/current.xbstream.zst"
SHA_CUR="${PHYS_DIR}/current.xbstream.zst.sha256"
SIZES_CUR="${PHYS_DIR}/current.sizes.txt"
META_CUR_HOST="${PHYS_DIR}/current.meta"

# -----------------------------------------------------------------------------
# Temporary build area INSIDE the datadir mount (mysql can write freely there)
# Host sees this as /export/mariadb/.tmp_backuppc
# -----------------------------------------------------------------------------
CT_TMP="/var/lib/mysql/.tmp_backuppc"
HOST_TMP="${ROOT}/.tmp_backuppc"

CT_TMP_PHYS="${CT_TMP}/physical"
CT_TMP_MY="${CT_TMP}/my"
CT_TMP_ETC="${CT_TMP}/etc"
CT_TMP_META="${CT_TMP}/meta"

# "current" artifacts inside temp (written by container tools)
CT_TMP_OUT="${CT_TMP_PHYS}/current.xbstream.zst"
CT_TMP_OUT_TMP="${CT_TMP_PHYS}/current.xbstream.zst.tmp"

CT_TMP_SHA="${CT_TMP_PHYS}/current.xbstream.zst.sha256"
CT_TMP_SHA_TMP="${CT_TMP_PHYS}/current.xbstream.zst.sha256.tmp"

CT_TMP_SIZES="${CT_TMP_PHYS}/current.sizes.txt"
CT_TMP_SIZES_TMP="${CT_TMP_PHYS}/current.sizes.txt.tmp"

CT_TMP_META_DIR="${CT_TMP_PHYS}/current.meta"
CT_TMP_META_TMP="${CT_TMP_PHYS}/current.meta.tmp"

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Prepare temp tree inside datadir (container-side)
# -----------------------------------------------------------------------------
log "Preparing temp staging tree inside container: ${CT_TMP}"
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
umask 022
rm -rf '${CT_TMP}'
mkdir -p '${CT_TMP_PHYS}' '${CT_TMP_MY}' '${CT_TMP_ETC}' '${CT_TMP_META}'

# clean any leftovers explicitly (belt & suspenders)
rm -f '${CT_TMP_OUT_TMP}' '${CT_TMP_SHA_TMP}' '${CT_TMP_SIZES_TMP}'
rm -rf '${CT_TMP_META_TMP}'

mkdir -p '${CT_TMP_META_TMP}'
"

# -----------------------------------------------------------------------------
# Create authoritative binlog boundary
# -----------------------------------------------------------------------------
log "Creating authoritative binlog boundary (FLUSH BINARY LOGS) ..."
incus exec "${CT_NAME}" -- /usr/bin/mariadb --socket="${DB_SOCKET}" -e "FLUSH BINARY LOGS;"

# -----------------------------------------------------------------------------
# Export grants/users (writes to /var/lib/mysql/grants.sql in your current setup)
# Then copy into temp tree so host can copy a self-contained set.
# -----------------------------------------------------------------------------
log "Exporting grants/users (container-local) ..."
incus exec "${CT_NAME}" -- /usr/local/sbin/export-mariadb-grants.sh

log "Copying grants.sql into temp tree ..."
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
umask 022
cp -a /var/lib/mysql/grants.sql '${CT_TMP_MY}/grants.sql'
chmod 0644 '${CT_TMP_MY}/grants.sql' || true
"

# -----------------------------------------------------------------------------
# Capture config + runtime metadata into temp tree (optional but recommended)
# -----------------------------------------------------------------------------
log "Capturing /etc/my.cnf.d into temp tree ..."
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
umask 022
rm -rf '${CT_TMP_ETC}/my.cnf.d'
mkdir -p '${CT_TMP_ETC}'
cp -a /etc/my.cnf.d '${CT_TMP_ETC}/my.cnf.d'
find '${CT_TMP_ETC}/my.cnf.d' -type d -exec chmod 0755 {} \; || true
find '${CT_TMP_ETC}/my.cnf.d' -type f -exec chmod 0644 {} \; || true
" || true

log "Capturing MariaDB runtime metadata into temp tree ..."
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
umask 022
/usr/bin/mariadb --socket='${DB_SOCKET}' -N -e 'SHOW MASTER STATUS\\G' > '${CT_TMP_META}/show-master-status.txt' || true
/usr/bin/mariadb --socket='${DB_SOCKET}' -N -e 'SHOW BINARY LOGS;' > '${CT_TMP_META}/show-binary-logs.txt' || true
/usr/bin/mariadb --socket='${DB_SOCKET}' -N -e \"
SHOW GLOBAL VARIABLES WHERE Variable_name IN
('version','log_bin','log_bin_basename','binlog_format','binlog_expire_logs_seconds','expire_logs_days','max_binlog_size');
\" > '${CT_TMP_META}/show-variables.txt' || true
chmod 0644 '${CT_TMP_META}'/*.txt 2>/dev/null || true
" || true

# -----------------------------------------------------------------------------
# Physical backup (mariadb-backup) - streamed + compressed + metadata captured
# Written completely inside CT_TMP, then atomically published to current.*
# -----------------------------------------------------------------------------
log "Running mariadb-backup into temp tree ..."
incus exec "${CT_NAME}" -- bash -lc "
set -euo pipefail
umask 022

# Ensure meta tmp exists and is empty
rm -rf '${CT_TMP_META_TMP}'
mkdir -p '${CT_TMP_META_TMP}'

# Stream backup into a temp file (so we never publish partial current.xbstream.zst)
mariadb-backup \
  --backup \
  --stream=xbstream \
  --extra-lsndir='${CT_TMP_META_TMP}' \
  --user=root \
  --socket='${DB_SOCKET}' \
| zstd -19 -T0 \
> '${CT_TMP_OUT_TMP}'

# Checksums and sizes (tmp)
sha256sum '${CT_TMP_OUT_TMP}' > '${CT_TMP_SHA_TMP}'
du -sh '${CT_TMP_OUT_TMP}' '${CT_TMP_META_TMP}' > '${CT_TMP_SIZES_TMP}' || true

# Publish atomically-ish: replace current meta + current stream
rm -rf '${CT_TMP_META_DIR}'
mv -f '${CT_TMP_META_TMP}' '${CT_TMP_META_DIR}'

mv -f '${CT_TMP_OUT_TMP}' '${CT_TMP_OUT}'
mv -f '${CT_TMP_SHA_TMP}' '${CT_TMP_SHA}'
mv -f '${CT_TMP_SIZES_TMP}' '${CT_TMP_SIZES}' 2>/dev/null || true

# Make sure host user can read (simple model: world-readable within temp)
#chmod 0755 '${CT_TMP}' '${CT_TMP_PHYS}' '${CT_TMP_MY}' '${CT_TMP_ETC}' '${CT_TMP_META}' '${CT_TMP_META_DIR}' || true
#find '${CT_TMP}' -type d -exec chmod 0755 {} \; || true
#find '${CT_TMP}' -type f -exec chmod 0644 {} \; || true
"

# -----------------------------------------------------------------------------
# Copy artifacts from temp tree (host view) into BackupPC core (owned by backuppc)
# -----------------------------------------------------------------------------
log "Copying staged artifacts from ${HOST_TMP} -> ${CORE} ..."
mkdir -p "${CORE}"
rsync -a --delete "${HOST_TMP}/" "${CORE}/"

# Tighten ownership/permissions for BackupPC readability/pooling.
# (If your BackupPC runs as a different user/group, adjust here.)
#log "Normalizing ownership/permissions under ${CORE} ..."
#chown -R "$(id -un)":"$(id -gn)" "${CORE}"
#find "${CORE}" -type d -exec chmod 0750 {} \; || true
#find "${CORE}" -type f -exec chmod 0640 {} \; || true

# -----------------------------------------------------------------------------
# Capture MariaDB config from inside container (/etc/my.cnf.d)
# -----------------------------------------------------------------------------
log "Capturing /etc/my.cnf.d from container ..."
rm -rf "${CORE}/etc/my.cnf.d"
mkdir -p "${CORE}/etc"
incus file pull -r "${CT_NAME}/etc/my.cnf.d" "${CORE}/etc/"

# -----------------------------------------------------------------------------
# Capture systemd unit/timer for binlog flush (host or container version)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Capture a small “state bundle” for restore decisions
# (Binlog position, binlog list, important variables)
# -----------------------------------------------------------------------------
log "Capturing MariaDB metadata (master status, binlog list, key variables) ..."
incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "SHOW MASTER STATUS\G" \
  > "${CORE}/meta/show-master-status.txt" || true

incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "SHOW BINARY LOGS;" \
  > "${CORE}/meta/show-binary-logs.txt" || true

incus exec "${CT_NAME}" -- /usr/bin/mariadb -N -e "
SHOW GLOBAL VARIABLES WHERE Variable_name IN
('version','log_bin','log_bin_basename','binlog_format','binlog_expire_logs_seconds','expire_logs_days','max_binlog_size');
" > "${CORE}/meta/show-variables.txt" || true

# -----------------------------------------------------------------------------
# Cleanup temp tree (container-side) and time stamp the run
# -----------------------------------------------------------------------------
log "Cleaning up container temp staging tree ${CT_TMP} ..."
incus exec "${CT_NAME}" -- bash -lc "rm -rf '${CT_TMP}'"
{
  echo "timestamp=$(date -Iseconds)"
  echo "container=${CT_NAME}"
  echo "host_root=${ROOT}"
} > "${CORE}/meta/stage-info.txt"

log "Pre-backup staging complete."
log "BackupPC should back up ${ROOT} excluding ${SERVICES}."
