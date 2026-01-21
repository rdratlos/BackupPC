# BackupPC Service Scripts - Shared Library Reference

## Overview

`/usr/local/lib/backuppc/common.sh` provides shared functions for BackupPC service backup scripts (pre/post hooks, staging helpers). It standardizes logging, locking, error handling, and container operations across all scripts.

## Quick Start

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

PHASE="init"
# ... your script logic
```

## Design Principles

| Principle            | Implementation                                      |
|----------------------|-----------------------------------------------------|
| **BackupPC alignment**   | Log/lock files follow BackupPC naming conventions   |
| **Fail-safe execution**  | Strict mode (`set -euo pipefail`) with phase tracking |
| **Privilege separation** | Uses sudo helpers for privileged operations         |
| **Minimal dependencies** | Bash 4.x, flock, logger, incus                      |

## File Locations

| Type    | Path                                  | Rationale                                       |
|---------|---------------------------------------|-------------------------------------------------|
| Library | `/usr/local/lib/backuppc/common.sh`     | Sourced, not executed → keeps `.sh`               |
| Logs    | `/var/log/backuppc/LOG.${SCRIPT_NAME}`  | Aligns with BackupPC's `LOG` / `LOG.YYMMDD` pattern |
| Locks   | `/var/log/backuppc/LOCK.${SCRIPT_NAME}` | Next to BackupPC's main `LOCK` file               |

## Variables

### Auto-set by Library

| Variable    | Description                     | Example                                           |
|-------------|---------------------------------|---------------------------------------------------|
| `SCRIPT_NAME` | Basename of calling script      | `backuppc-svc-nextcloud-pre`                        |
| `LOG_FILE`    | Full path to script's log file  | `/var/log/backuppc/LOG.backuppc-svc-nextcloud-pre`  |
| `LOCK_FILE`   | Full path to script's lock file | `/var/log/backuppc/LOCK.backuppc-svc-nextcloud-pre` |
| `LOG_TAG`     | Syslog tag                      | `backuppc/backuppc-svc-nextcloud-pre`               |

### Failure State (set by `fail()` / `on_err`)

| Variable   | Description                                |
|------------|--------------------------------------------|
| `PHASE`      | Current execution phase (script sets this) |
| `FAILED`     | Failure flag: `0` = success, `1` = failed      |
| `FAIL_RC`    | Captured exit code                         |
| `FAIL_MSG`   | Error message                              |
| `FAIL_PHASE` | Phase where failure occurred               |
| `FAIL_LINE`  | Line number of failure                     |
| `FAIL_CMD`   | Command that triggered failure             |

## Core Functions

### Initialization

| Function            | Purpose                                                   |
|---------------------|-----------------------------------------------------------|
| `enable_strict_traps` | Install ERR + EXIT traps for comprehensive error handling |

### Logging

All logging writes to: syslog, script log file, and console.

| Function    | Level | Output                   |
|-------------|-------|--------------------------|
| `log "msg"`   | INFO  | stdout                   |
| `warn "msg"`  | WARN  | stderr                   |
| `error "msg"` | ERROR | stderr                   |
| `debug "msg"` | DEBUG | stdout (only if `DEBUG=1`) |

### Error Handling

| Function            | Purpose                              |
|---------------------|--------------------------------------|
| `fail <rc> "msg"`     | Set failure state and exit with code |
| `die "msg"`           | Shorthand for `fail 1 "msg"`           |
| `get_failure_summary` | Return structured failure info       |

### Locking

| Function            | Purpose                                    |
|---------------------|--------------------------------------------|
| `acquire_lock [name]` | Get exclusive lock (default: `$SCRIPT_NAME`) |
| `release_lock`        | Release lock (automatic on exit)           |

### Cleanup

| Function               | Purpose                                     |
|------------------------|---------------------------------------------|
| `register_cleanup "cmd"` | Register action to run on exit (LIFO order) |

### Validation

| Function               | Purpose                         |
|------------------------|---------------------------------|
| `require_var VAR_NAME`   | Fail if variable unset/empty    |
| `require_command cmd`    | Fail if command not found       |
| `require_file path`      | Fail if file missing/unreadable |
| `require_directory path` | Fail if directory missing       |

### Staging Operations

| Function                        | Purpose                                 |
|---------------------------------|-----------------------------------------|
| `cleanup_staging "dir"`           | Remove staging contents via sudo helper |
| `ensure_staging_dir "dir" [mode]` | Create directory if missing             |

### Container Operations (Incus)

| Function                                 | Purpose                                           |
|------------------------------------------|---------------------------------------------------|
| `extract_container_path <ct> <src> <dest>` | Stream tar from container, restore with ownership |
| `container_exists <ct>`                    | Check if container exists                         |
| `container_running <ct>`                   | Check if container is running                     |
| `wait_container_ready <ct> [timeout]`      | Wait for container to be ready (default: 30s)     |

### Timing

| Function                 | Purpose             |
|--------------------------|---------------------|
| `timer_start "name"`       | Start named timer   |
| `timer_elapsed "name"`     | Get elapsed seconds |
| `timer_log "name" ["msg"]` | Log elapsed time    |

### Utilities

| Function                      | Purpose                       |
|-------------------------------|-------------------------------|
| `is_root`                       | Check if running as root      |
| `is_backuppc_user`              | Check if running as backuppc  |
| `bytes_to_human <n>`            | Convert bytes to human format |
| `load_config "file" [required]` | Source config file            |

## Exit Codes

| Code | Meaning                        |
|------|--------------------------------|
| 0    | Success                        |
| 1    | General error                  |
| 2    | Configuration/validation error |
| 3    | Staging operation failed       |
| 4    | Container operation failed     |
| 5    | Timeout                        |
| 10   | Lock acquisition failed        |

## Example: Service Pre-Backup Script

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

## Related Files

| File                                     | Purpose                           |
|------------------------------------------|-----------------------------------|
| `/usr/local/sbin/backuppc-staging-cleanup` | Privileged staging cleanup helper |
| `/usr/local/sbin/tarCreate`                | Privileged tar create wrapper     |
| `/usr/local/sbin/tarRestore`               | Privileged tar restore wrapper    |
| `/etc/backuppc/staging-roots.conf`         | Allowed staging directories       |

---

*Parent: [BackupPC Service Backup Implementation](https://claude.ai/chat/a7a10d81-b9ae-4809-936b-054df850a467)*