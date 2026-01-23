# Overview

The `backuppc-staging-cleanup` helper provides controlled elevation for removing staging directory contents. Staging directories contain files with container-shifted UIDs (100000+) that the unprivileged `backuppc` user cannot remove directly.

# Files

| File                     | Path                                     | Purpose                    |
|--------------------------|------------------------------------------|----------------------------|
| `backuppc-staging-cleanup` | `/usr/local/sbin/backuppc-staging-cleanup` | Privileged cleanup helper  |
| `staging-roots.conf`       | `/etc/backuppc/staging-roots.conf`         | Allowlist of staging roots |

# Installation

```bash
# Install the cleanup helper
sudo install -m 755 -o root -g root backuppc-staging-cleanup /usr/local/sbin/

# Install and configure the allowlist
sudo install -m 644 -o root -g root staging-roots.conf /etc/backuppc/

# Edit to add your staging roots
sudo vim /etc/backuppc/staging-roots.conf

# Add sudoers entry
echo 'backuppc ALL=(root) NOPASSWD: /usr/local/sbin/backuppc-staging-cleanup' | \
    sudo tee /etc/sudoers.d/backuppc-staging-cleanup
sudo chmod 440 /etc/sudoers.d/backuppc-staging-cleanup
```

# Security Model

1. **Allowlist-based**: Only paths under roots defined in `staging-roots.conf` are accepted
2. **Depth validation**: Target must be at least 2 levels below an allowed root (prevents cleaning the root itself or service directories)
3. **Config file security**: `staging-roots.conf` must be owned by `root:root` and not world-writable
4. **Path canonicalization**: Uses `realpath` to prevent symlink traversal attacks
5. **System path blocklist**: Explicitly rejects `/`, `/etc`, `/var`, `/home`, etc.
6. **Single purpose**: No flags, no options, just one directory argument

# Exit Codes

| Code | Meaning                                                              |
|------|----------------------------------------------------------------------|
| 0    | Success (contents removed, or target didn't exist)                   |
| 1    | Usage error (wrong number of arguments)                              |
| 2    | Configuration error (missing/insecure config file)                   |
| 3    | Path validation failed (not in allowlist, too shallow, or dangerous) |
| 4    | Target is not a directory                                            |
| 5    | Cleanup operation failed                                             |

# Usage Examples

## Direct invocation (as root or via sudo)

```bash
# Clean a specific service staging directory
sudo /usr/local/sbin/backuppc-staging-cleanup /srv/backuppc-staging/nextcloud/etc

# From common.sh (as backuppc user)
cleanup_staging "$STAGING_DIR"
```

## Integration with common.sh

The `cleanup_staging()` function in `common.sh` wraps this helper:

```bash
cleanup_staging() {
    local dir="$1"
    require_var dir "cleanup_staging: directory required"

    log "Cleaning staging directory: $dir"
    if ! sudo /usr/local/sbin/backuppc-staging-cleanup "$dir"; then
        fail 3 "Failed to clean staging directory: $dir"
    fi
}
```

# Configuration Format

`/etc/backuppc/staging-roots.conf`:

```conf
# BackupPC staging roots - one per line
# Comments start with #, blank lines ignored

# Default staging area
/srv/backuppc-staging

# Service-specific roots (if using separate volumes)
# /var/lib/mysql-staging
# /mnt/fast-nvme/backuppc-staging
```

# Depth Calculation

The minimum depth (default: 2) prevents accidental cleanup of high-level directories:

| Path                                    | Relative to Root  | Depth | Result                    |
|-----------------------------------------|-------------------|-------|---------------------------|
| `/srv/backuppc-staging`                   | (is the root)     | 0     | **Rejected** (not under root) |
| `/srv/backuppc-staging/nextcloud`         | `nextcloud`         | 1     | **Rejected** (too shallow)    |
| `/srv/backuppc-staging/nextcloud/etc`     | `nextcloud/etc`     | 2     | ✅ Allowed                 |
| `/srv/backuppc-staging/nextcloud/var/www` | `nextcloud/var/www` | 3     | ✅ Allowed                 |

# Behavior Notes

- **Non-existent targets**: Exit 0 with informational message (idempotent)
- **Permission handling**: Runs `chmod u+wx` on directories before deletion to handle container-shifted permissions
- **Filesystem boundaries**: Uses `find -xdev` to stay on the same filesystem
- **Directory preservation**: Removes contents but keeps the target directory itself

# Testing

The implementation was validated against these scenarios:

| Test Case               | Expected                 | Actual |
|-------------------------|--------------------------|--------|
| No arguments            | Exit 1                   | ✅      |
| Too many arguments      | Exit 1                   | ✅      |
| Root directory `/`        | Exit 3                   | ✅      |
| System directory `/etc`   | Exit 3                   | ✅      |
| Staging root itself     | Exit 3                   | ✅      |
| One level deep          | Exit 3                   | ✅      |
| Two levels deep         | Exit 0, contents removed | ✅      |
| Non-existent valid path | Exit 0                   | ✅      |
| Wrong config ownership  | Exit 2                   | ✅      |
| World-writable config   | Exit 2                   | ✅      |

# Sudoers Integration

Complete sudoers configuration for BackupPC:

```sudoers
# /etc/sudoers.d/backuppc
# BackupPC tar operations
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarCreate
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarRestore

# BackupPC staging cleanup
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/backuppc-staging-cleanup
```

---