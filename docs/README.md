# Documentation Index

Reference documentation for the BackupPC Services Backup Suite.

## Core Documentation

| Document | Description |
|----------|-------------|
| [Shared Library Reference.md](Shared%20Library%20Reference.md) | Complete API reference for `common.sh` — logging, error handling, container operations, bind mounts, validation helpers |
| [BackupPC Staging Extract Helper.md](BackupPC%20Staging%20Extract%20Helper.md) | Privileged helper for extracting files from containers with ownership preservation |
| [BackupPC Staging Cleanup Helper.md](BackupPC%20Staging%20Cleanup%20Helper.md) | Privileged helper for safely cleaning staging directories |

## Templates

The [templates/](templates/) directory contains annotated script templates for creating new service backup scripts:

| Template | Description |
|----------|-------------|
| [backuppc-svc-example-pre](templates/backuppc-svc-example-pre) | Pre-backup script template with customization guidance |
| [backuppc-svc-example-post](templates/backuppc-svc-example-post) | Post-backup script template with validation patterns |

### Using Templates

1. Copy the template to `svc/` with your service name
2. Search for `<` to find all customization points
3. Implement service-specific functions
4. Add tests to `tests/`

## Quick Reference

### Script Lifecycle

```
BackupPC                  Pre-Script                    BackupPC                         Post-Script
───────────────────────────────────────────────────────────────────────────────────────────────────────────
DumpPreUserCmd ────────▶ acquire_lock
                          prepare_staging
                          ensure_bind_mount
                          enable_maintenance_mode
                          dump_database
                          extract_config
                          capture_package_lists
                          generate_summary
                          exit 0 (success) ──────────▶ rsync/tar staging view
                          (cleanup: disable maint.)     to BackupPC pool

                                                        DumpPostUserCmd ─(xferOK=0|1)─▶ init_xfer_status
                                                                                         validate_artifacts
                                                                                         write_meta_status
                                                                                         remove_bind_mount
                                                                                         cleanup_if_success
```

### Exit Code Summary

| Range | Category | Handler |
|-------|----------|---------|
| 0 | Success | — |
| 1-9 | General errors | `die()`, `fail()` |
| 10-19 | Lock errors | `acquire_lock()` |
| 20-29 | Mount errors | `ensure_bind_mount()` |
| 30-39 | Database errors | Service-specific |
| 40-49 | Validation errors | Service-specific |
| 50-59 | Extraction errors | Service-specific |
| 60-69 | Post-validation errors | `verify_*()` |

### Common Patterns

**Phase tracking:**
```bash
PHASE="database_dump"
dump_database
PHASE="config_extract"
extract_config
```

**Registered cleanup:**
```bash
enable_maintenance_mode
register_cleanup "disable_maintenance_mode"
# disable_maintenance_mode runs automatically on exit
```

**Artifact validation:**
```bash
errors=0
verify_zstd_file "$STAGING/dump.sql.zst" "Database dump" || errors=$((errors + 1))
verify_file_checksum "$STAGING/dump.sql.zst" || errors=$((errors + 1))
[[ $errors -gt 0 ]] && fail 60 "Validation failed"
```

## Related Files

| Path | Description |
|------|-------------|
| `/usr/local/lib/backuppc/common.sh` | Shared library (source of truth) |
| `/etc/backuppc/staging.conf` | Allowed staging roots |
| `/var/log/backuppc/LOG.*` | Per-script log files |
| `/var/log/backuppc/LOCK.*` | Lock files |
