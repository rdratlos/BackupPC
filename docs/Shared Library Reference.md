# Overview

`/usr/local/lib/backuppc/common.sh` provides shared functions for BackupPC service backup scripts (pre/post hooks, staging helpers). It standardizes logging, locking, error handling, and container operations across all scripts.

# Quick Start

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

PHASE="init"
# ... your script logic
```

# Design Principles

| Principle            | Implementation                                                    |
|----------------------|-------------------------------------------------------------------|
| **BackupPC alignment**   | Log/lock files follow BackupPC naming conventions                 |
| **Fail-safe execution**  | Strict mode (`set -euo pipefail -E`) with phase tracking            |
| **Privilege separation** | Uses sudo helpers for privileged operations                       |
| **Minimal dependencies** | Bash 4.x, flock, logger, realpath, mktemp, incus, zstd, sha256sum |

# File Locations

| Type    | Path                                  | Rationale                                       |
|---------|---------------------------------------|-------------------------------------------------|
| Library | `/usr/local/lib/backuppc/common.sh`     | Sourced, not executed → keeps `.sh`               |
| Logs    | `/var/log/backuppc/LOG.${SCRIPT_NAME}`  | Aligns with BackupPC's `LOG` / `LOG.YYMMDD` pattern |
| Locks   | `/var/log/backuppc/LOCK.${SCRIPT_NAME}` | Next to BackupPC's main `LOCK` file               |

# Variables

## Auto-set by Library

| Variable    | Description                     | Example                                           |
|-------------|---------------------------------|---------------------------------------------------|
| `SCRIPT_NAME` | Basename of calling script      | `backuppc-svc-nextcloud-pre`                        |
| `LOG_FILE`    | Full path to script's log file  | `/var/log/backuppc/LOG.backuppc-svc-nextcloud-pre`  |
| `LOCK_FILE`   | Full path to script's lock file | `/var/log/backuppc/LOCK.backuppc-svc-nextcloud-pre` |
| `LOG_TAG`     | Syslog tag                      | `backuppc/backuppc-svc-nextcloud-pre`               |

## Failure State (set by `fail()` / `on_err`)

| Variable   | Description                                |
|------------|--------------------------------------------|
| `PHASE`      | Current execution phase (script sets this) |
| `FAILED`     | Failure flag: `0` = success, `1` = failed      |
| `FAIL_RC`    | Captured exit code                         |
| `FAIL_MSG`   | Error message                              |
| `FAIL_PHASE` | Phase where failure occurred               |
| `FAIL_LINE`  | Line number of failure                     |
| `FAIL_CMD`   | Command that triggered failure             |

# Core Functions

## Initialization

| Function            | Purpose                                                   |
|---------------------|-----------------------------------------------------------|
| `enable_strict_traps` | Install ERR + EXIT traps for comprehensive error handling |

## Logging

All logging writes to: syslog, script log file, and stderr (keeps stdout clean).

| Function    | Level | Description                  |
|-------------|-------|------------------------------|
| `log "msg"`   | INFO  | General information          |
| `warn "msg"`  | WARN  | Warning conditions           |
| `error "msg"` | ERROR | Error conditions             |
| `debug "msg"` | DEBUG | Debug info (only if `DEBUG=1`) |

## Error Handling

| Function            | Purpose                              |
|---------------------|--------------------------------------|
| `fail <rc> "msg"`     | Set failure state and exit with code |
| `die "msg"`           | Shorthand for `fail 1 "msg"`           |
| `get_failure_summary` | Return structured failure info       |

## Locking

| Function            | Purpose                                      |
|---------------------|----------------------------------------------|
| `acquire_lock [name]` | Get exclusive lock (default: `$SCRIPT_NAME`)   |
| `release_lock`        | Release lock (automatic on exit via cleanup) |

## Cleanup

| Function               | Purpose                                     |
|------------------------|---------------------------------------------|
| `register_cleanup "cmd"` | Register action to run on exit (LIFO order) |

## Validation

| Function               | Purpose                         |
|------------------------|---------------------------------|
| `require_var VAR_NAME`   | Fail if variable unset/empty    |
| `require_command cmd`    | Fail if command not found       |
| `require_file path`      | Fail if file missing/unreadable |
| `require_directory path` | Fail if directory missing       |

## Staging Operations

| Function                        | Purpose                                 |
|---------------------------------|-----------------------------------------|
| `cleanup_staging "dir"`           | Remove staging contents via sudo helper |
| `ensure_staging_dir "dir" [mode]` | Create directory if missing             |

## Bind Mount Operations

| Function                       | Purpose                                    |
|--------------------------------|--------------------------------------------|
| `ensure_bind_mount <src> <dest>` | Create or verify bind mount exists         |
| `remove_bind_mount <dest>`       | Unmount bind mount (safe for post-scripts) |

**Bind mount behavior:**

- `ensure_bind_mount` creates directories if needed, verifies correct source if already mounted
- `remove_bind_mount` never fails the script (returns 0 even if busy) - intentional for post-backup cleanup
- Both resolve symlinks for consistent comparison

## Container Operations (Incus)

| Function                                    | Purpose                                               |
|---------------------------------------------|-------------------------------------------------------|
| `container_exists <ct>`                       | Check if container exists                             |
| `container_running <ct>`                      | Check if container is running                         |
| `wait_container_ready <ct> [timeout]`         | Wait for container to be ready (default: 30s)         |
| `extract_container_path <ct> <src> <dest>`    | Extract path relative to `/`, preserving structure      |
| `extract_container_dir <ct> <src> <dest>`     | Extract directory contents only (no parent structure) |
| `copy_container_dir <ct> <src> <dest>`        | Copy directory contents (backuppc ownership)          |
| `capture_container_package_lists <ct> <dest>` | Capture pacman package lists (Arch/Manjaro)           |
| `require_container_command <ct> <cmd>`        | Fail if command not available in container            |

**Extraction functions compared:**

```bash
# extract_container_path: preserves path structure from root
extract_container_path ct-app etc/myapp /srv/staging
# → /srv/staging/etc/myapp/...

# extract_container_dir: extracts contents only, preserves ownership
extract_container_dir ct-mariadb /var/lib/mysql/db/binlogs /export/staging/db
# → /export/staging/db/<binlog files> (original ownership via tarRestore)

# copy_container_dir: extracts contents only, backuppc ownership
copy_container_dir ct-mariadb /tmp/dump /staging/dump
# → /staging/dump/<files> (owned by backuppc user)
```

## Timing

| Function                 | Purpose             |
|--------------------------|---------------------|
| `timer_start "name"`       | Start named timer   |
| `timer_elapsed "name"`     | Get elapsed seconds |
| `timer_log "name" ["msg"]` | Log elapsed time    |

## Configuration

| Function                      | Purpose                                  |
|-------------------------------|------------------------------------------|
| `load_config "file" [required]` | Source config file (optional by default) |

## Utilities

| Function           | Purpose                       |
|--------------------|-------------------------------|
| `is_root`            | Check if running as root      |
| `is_backuppc_user`   | Check if running as backuppc  |
| `bytes_to_human <n>` | Convert bytes to human format |

# Post-Script Functions

These functions support post-backup scripts that need to handle BackupPC transfer status and validate backup artifacts.

## Transfer Status

| Variable | Description                                        |
|----------|----------------------------------------------------|
| `XFER_OK`  | BackupPC transfer status: `0` = failure, `1` = success |

| Function                                            | Purpose                                                      |
|-----------------------------------------------------|--------------------------------------------------------------|
| `init_xfer_status <expected> <actual> [xferOK]`       | Validate cmdType and parse xferOK status                     |
| `should_preserve_staging`                             | Returns 0 (true) if staging should be kept for investigation |

**Parameters for `init_xfer_status`:**

- `<expected>` - The command type this script expects (e.g., `"DumpPostUserCmd"`)
- `<actual>` - The actual `$cmdType` passed by BackupPC (`$1`)
- `[xferOK]` - The `$xferOK` value from BackupPC (`$2`) - required for post-commands, ignored for pre-commands

**Usage:**

```bash
# In post-backup script (DumpPostUserCmd)
# BackupPC config: $Conf{DumpPostUserCmd} = '/path/to/script $cmdType $xferOK';
init_xfer_status "DumpPostUserCmd" "$1" "$2"

# In pre-backup script (DumpPreUserCmd)
# BackupPC config: $Conf{DumpPreUserCmd} = '/path/to/script $cmdType';
init_xfer_status "DumpPreUserCmd" "$1"

if should_preserve_staging; then
    warn "Preserving staging for investigation (XFER_OK=$XFER_OK, FAILED=$FAILED)"
else
    cleanup_staging "$STAGING_DIR"
fi
```

## Meta Directory Operations

Post-scripts record status in a `meta/` subdirectory for diagnostics and monitoring.

| Function                                     | Purpose                                |
|----------------------------------------------|----------------------------------------|
| `write_meta_xferok <dir>`                      | Write `xferOK` and `finished_at` timestamp |
| `write_meta_status <dir> <status> [error_msg]` | Write `status` and optional `error` file   |

**Files created:**

| File             | Content                            |
|------------------|------------------------------------|
| `meta/xferOK`      | `0` or `1`                             |
| `meta/finished_at` | ISO 8601 timestamp                 |
| `meta/status`      | `ok` or `failed`                       |
| `meta/error`       | Error message (cleared on success) |

## Artifact Validation

| Function                             | Purpose                                      | Returns                  |
|--------------------------------------|----------------------------------------------|--------------------------|
| `verify_zstd_file <file> [desc]`       | Verify zstd file exists and passes integrity | 0=ok, 1=fail             |
| `verify_file_checksum <file>`          | Verify SHA256 sidecar (`.sha256`)              | 0=ok/missing, 1=mismatch |
| `verify_directory_exists <dir> [desc]` | Check directory exists (warns if empty)      | 0=exists, 1=missing      |
| `verify_file_exists <file> [desc]`     | Check file exists and is readable            | 0=ok, 1=fail             |

**Usage:**

```bash
PHASE="validation"
errors=0

# Verify compressed dump
if ! verify_zstd_file "$STAGING/dump.sql.zst" "MariaDB dump"; then
    errors=$((errors + 1))
else
    # Also verify checksum if present
    if ! verify_file_checksum "$STAGING/dump.sql.zst"; then
        errors=$((errors + 1))
    fi
fi

# Verify directory has content
if ! verify_directory_exists "$STAGING/binlogs" "Binary logs"; then
    errors=$((errors + 1))
fi

if [[ $errors -gt 0 ]]; then
    fail 60 "Artifact validation failed ($errors error(s))"
fi
```

# Exit Codes

## Library Reserved Codes (0-29)

These exit codes are reserved for the common.sh library and should not be used by service scripts:

| Code | Meaning                              | Used By                        |
|------|--------------------------------------|--------------------------------|
| 0    | Success                              | All scripts                    |
| 1    | General error / `die()`              | `die()`, general failures      |
| 2    | Configuration/validation error       | `require_*`, `load_config`     |
| 3    | Staging operation failed             | `cleanup_staging`, `ensure_staging_dir` |
| 4    | Container operation failed           | `extract_*`, `copy_*`, `wait_container_ready` |
| 5    | Timeout / temp file creation failed  | `wait_container_ready`, `mktemp` failures |
| 10   | Lock acquisition failed              | `acquire_lock`                 |
| 20   | Mount verification failed            | `ensure_bind_mount`            |

## Service-Specific Codes (30-99)

Service scripts should use exit codes in the range **30-99** for service-specific errors. This ensures no collision with library codes.

**Recommended structure for service scripts:**

| Range | Category                    | Example Usage                          |
|-------|-----------------------------|----------------------------------------|
| 30-39 | Database operation errors   | Connection failed, query error, dump failed |
| 40-49 | Service-specific validation | Missing config, invalid state          |
| 50-59 | Extraction/transfer errors  | Failed to extract files, permission denied |
| 60-69 | Post-backup validation      | Artifact missing, checksum mismatch    |
| 70-99 | Reserved for future use     | -                                      |

**Example service script exit codes:**

```bash
# MariaDB service script examples:
fail 30 "Database connection failed"
fail 31 "Failed to flush binary logs"
fail 32 "Failed to record binlog position"
fail 40 "Binary logging not enabled"
fail 60 "Dump artifact validation failed"
fail 61 "Checksum verification failed"
```

## High-Value Codes (100+)

Codes 100 and above may have special meanings in some contexts:

| Code    | Meaning                              |
|---------|--------------------------------------|
| 126     | Command found but not executable     |
| 127     | Command not found                    |
| 128+N   | Fatal signal N (e.g., 137 = SIGKILL) |

**Note:** Avoid using codes above 125 in your scripts as they may be interpreted as signal-related exits by shells and process managers.

# Example: Service Pre-Backup Script

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

SERVICE="nextcloud"
CONTAINER="ct-${SERVICE}"
STAGING="/srv/backuppc-staging/${SERVICE}"

cleanup_on_failure() {
    [[ "$FAILED" -ne 0 ]] && warn "Rolling back: $FAIL_PHASE"
}
register_cleanup "cleanup_on_failure"

PHASE="locking"
acquire_lock "$SERVICE"

PHASE="staging_prep"
cleanup_staging "$STAGING"
ensure_staging_dir "$STAGING/etc"

PHASE="extraction"
extract_container_path "$CONTAINER" "etc/nextcloud" "$STAGING/etc"

PHASE="complete"
log "Staging ready: $STAGING"
```

# Example: Service Post-Backup Script

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

SERVICE="mariadb"
STAGING="/export/${SERVICE}/backuppc/staging"
VIEW_DIR="/export/${SERVICE}/backuppc/view"
META_DIR="${STAGING}/meta"

# Parse BackupPC transfer status
PHASE="init"
init_xfer_status "DumpPostUserCmd" "$1" "$2"
log "Post-backup: XFER_OK=$XFER_OK"

# Validate artifacts if transfer succeeded
if [[ "$XFER_OK" -eq 1 ]]; then
    PHASE="validation"
    errors=0
    verify_zstd_file "${STAGING}/dump.sql.zst" "MariaDB dump" || errors=$((errors + 1))
    verify_file_checksum "${STAGING}/dump.sql.zst" || errors=$((errors + 1))
    verify_directory_exists "${STAGING}/binlogs" "Binary logs" || errors=$((errors + 1))
    
    if [[ $errors -gt 0 ]]; then
        fail 60 "Artifact validation failed ($errors error(s))"
    fi
fi

# Record status
PHASE="meta"
write_meta_xferok "$META_DIR"
if [[ "$FAILED" -eq 0 && "$XFER_OK" -eq 1 ]]; then
    write_meta_status "$META_DIR" "ok"
else
    write_meta_status "$META_DIR" "failed" "$(get_failure_summary)"
fi

# Cleanup
PHASE="cleanup"
remove_bind_mount "$VIEW_DIR"

if should_preserve_staging; then
    warn "Preserving staging for investigation"
else
    log "Backup successful, staging preserved for next run"
fi

PHASE="complete"
log "Post-backup finished"
```

# Related Files

| File                                     | Purpose                           |
|------------------------------------------|-----------------------------------|
| `/usr/local/sbin/backuppc-staging-cleanup` | Privileged staging cleanup helper |
| `/usr/local/sbin/tarCreate`                | Privileged tar create wrapper     |
| `/usr/local/sbin/tarRestore`               | Privileged tar restore wrapper    |
| `/etc/backuppc/staging-roots.conf`         | Allowed staging directories       |

# Sudoers Requirements

The following commands must be configured in sudoers for user `backuppc`:

```sudoers
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarCreate
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarRestore
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/backuppc-staging-cleanup
backuppc ALL=(root) NOPASSWD: /usr/bin/mount --bind *
backuppc ALL=(root) NOPASSWD: /usr/bin/umount *
```

---

*Parent: [BackupPC Service Backup Implementation](https://claude.ai/chat/a7a10d81-b9ae-4809-936b-054df850a467)*
