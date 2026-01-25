# Overview

The `backuppc-staging-extract` helper extracts files from Incus containers to host staging directories, preserving ownership and permissions through a tar stream pipeline. This enables BackupPC to see container filesystems as if they were regular host directories, while maintaining the shifted UIDs required for accurate backup and restoration of unprivileged containers.

**Key design principle:** The script runs as user `backuppc` and internally calls `sudo tarRestore` for privilege elevation. No sudo is needed to call the script itself.

# Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Extraction Flow                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌────────────────┐    tar stream      ┌────────────────┐                   │
│  │ Incus Container│ ──────────────────▶│ sudo tarRestore│                   │
│  │                │                    │ (internal call)│                   │
│  │  tar -cf - ... │                    │                │                   │
│  │  (as root)     │                    │ tar -xf - ...  │                   │
│  └────────────────┘                    └───────┬────────┘                   │
│                                                │                            │
│                                                ▼                            │
│                                    ┌────────────────────┐                   │
│                                    │ Staging Directory  │                   │
│                                    │                    │                   │
│                                    │ /srv/backuppc-     │                   │
│                                    │  staging/nextcloud │                   │
│                                    │                    │                   │
│                                    │ Files with shifted │                   │
│                                    │ UIDs (100000+)     │                   │
│                                    └─────────┬──────────┘                   │
│                                              │                              │
│                                              ▼                              │
│                                    ┌────────────────────┐                   │
│                                    │ BackupPC           │                   │
│                                    │ (rsync/tar backup) │                   │
│                                    │                    │                   │
│                                    │ Sees container as  │                   │
│                                    │ regular "host"     │                   │
│                                    └────────────────────┘                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Files

| File                     | Path                                     | Purpose                                                |
|--------------------------|------------------------------------------|--------------------------------------------------------|
| `backuppc-staging-extract` | `/usr/local/sbin/backuppc-staging-extract` | Main extraction helper                                 |
| `staging.conf`             | `/etc/backuppc/staging.conf`               | Unified staging allowlist (shared with cleanup helper) |

# Installation

```bash
# Install the extraction helper
sudo install -m 755 -o root -g root backuppc-staging-extract /usr/local/sbin/

# Install unified staging config (if not already present from cleanup helper)
sudo install -m 644 -o root -g root staging.conf /etc/backuppc/

# Edit to add your staging roots
sudo vim /etc/backuppc/staging.conf
```

**Note:** No separate sudoers entry is needed for this script. It uses the existing `tarRestore` sudo permission that's standard for BackupPC installations:

```bash
# Already in sudoers for BackupPC:
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarRestore
```

# Usage

## Basic Syntax

```bash
backuppc-staging-extract <container> <staging_dir> <path> [path...]
backuppc-staging-extract <container> <staging_dir> --file-list <listfile>
```

**Note:** Run as user `backuppc` (or whoever has sudo permission for tarRestore). No sudo needed to call the script.

## Examples

```bash
# Extract /etc directory from container
backuppc-staging-extract ct-nextcloud /srv/backuppc-staging/nextcloud etc

# Extract multiple specific paths
backuppc-staging-extract ct-mariadb /srv/backuppc-staging/mariadb \
    etc/my.cnf.d \
    var/lib/mysql/.my.cnf

# Extract paths defined in file
backuppc-staging-extract ct-nginx /srv/backuppc-staging/nginx \
    --file-list /etc/backuppc/nginx-paths.txt
```

## Path List File Format

```
# /etc/backuppc/nginx-paths.txt
# Lines starting with # are comments
# Paths are relative to container root (no leading /)

etc/nginx
etc/ssl/certs
var/www/html
```

# Security Model

## 1. Allowlist-Based Path Validation

Only staging directories under roots defined in `staging.conf` are accepted:

```bash
# In staging.conf:
/srv/backuppc-staging

# These work:
backuppc-staging-extract ct-app /srv/backuppc-staging/myapp etc    ✓

# These are rejected:
backuppc-staging-extract ct-app /srv/backuppc-staging etc          ✗ (is root, not under)
backuppc-staging-extract ct-app /tmp/staging etc                   ✗ (not under allowed root)
```

## 2. Configuration File Security

- **Ownership**: Must be `root:root`
- **Permissions**: Must not be writable by group/other (644 or stricter)
- Validated before reading to prevent config injection attacks

## 3. Container Path Validation

- **No traversal**: Paths with `..` components are rejected
- **Relative only**: Absolute paths (starting with `/`) are rejected
- **Non-empty**: Empty paths are rejected

## 4. Container Validation

- Container must exist
- Container must be running (state = RUNNING)

## 5. Internal Privilege Elevation

The script uses `sudo tarRestore` internally for the actual file extraction. This leverages the existing BackupPC sudoers configuration rather than requiring a new sudo entry for the script itself.

# Tar Options Used

The helper uses specific tar options for complete metadata preservation:

| Option                 | Purpose                                                 |
|------------------------|---------------------------------------------------------|
| `--format=posix`         | POSIX.1-2001 (pax) format for extended attributes       |
| `--numeric-owner`        | Store UIDs/GIDs numerically (critical for shifted UIDs) |
| `--preserve-permissions` | Preserve file permissions                               |

These options ensure that files backed up from unprivileged containers retain their shifted UIDs (100000+) in the staging directory, which BackupPC then preserves in its pool.

# Exit Codes

| Code | Meaning                                  |
|------|------------------------------------------|
| 0    | Success                                  |
| 1    | Invalid arguments                        |
| 2    | Configuration error                      |
| 3    | Security validation failed               |
| 4    | Container error (not found, not running) |
| 5    | Extraction failed                        |

# Design: Self-Contained Helper

This script is intentionally self-contained and does **not** source `common.sh`. Rationale:

- **Helpers are primitives** — Called by service scripts, not meant to be libraries
- **Minimal dependencies** — Works even if `common.sh` isn't installed
- **No variable conflicts** — Avoids readonly variable collisions
- **Clear separation** — Service scripts source `common.sh`; helpers are standalone

Service pre-backup scripts should use `common.sh` functions like `extract_container_path()` which internally builds the same tar pipeline:

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

# common.sh's extract_container_path uses the same tar | sudo tarRestore pattern
extract_container_path "ct-nextcloud" "etc/nextcloud" "/srv/backuppc-staging/nextcloud"
```

Or call this helper directly for file-list support:

```bash
#!/bin/bash
source /usr/local/lib/backuppc/common.sh
enable_strict_traps

log "Extracting container configuration"
if ! /usr/local/sbin/backuppc-staging-extract \
    "$CONTAINER" \
    "$STAGING_DIR" \
    --file-list "/etc/backuppc/${SERVICE}-paths.txt"; then
    fail 5 "Extraction failed"
fi
```

# Testing

## Running Tests

```bash
# Unit tests (no container required)
sudo ./tests/test-staging-extract.sh

# Integration tests (specify test container)
sudo TEST_CONTAINER=ct-test ./tests/test-staging-extract.sh

# Skip container tests entirely
sudo SKIP_CONTAINER=1 ./tests/test-staging-extract.sh
```

## Test Coverage

**Security Validation:**

- Argument validation
- Configuration file security (ownership, permissions)
- Allowlist enforcement
- Path traversal prevention
- Container path validation

**Container Operations:**

- Non-existent container handling
- Container state validation
- Path existence checking

**Extraction Operations:**

- Single path extraction
- Multiple paths extraction
- File list extraction
- UID preservation verification

# Design Decisions

## Why Extract Rather Than Store as Tar?

With 200+ containers sharing common base images, BackupPC's file-level deduplication provides massive storage savings. The identical PAM configs, SSSD setups, and base `/etc` structures across containers collapse into single pool entries. Storing pre-made tar archives would lose this deduplication benefit.

## Why Use sudo tarRestore Internally?

The `tarRestore` wrapper is already enabled in sudoers for BackupPC host backup operations. By calling it internally:

- No new sudoers entry needed for this script
- Maintains consistent privilege model
- Preserves all file metadata including shifted UIDs
- Aligns with BackupPC's own tar-based backup strategy

## Why a Unified staging.conf?

Both `backuppc-staging-cleanup` and `backuppc-staging-extract` need the same information (allowed staging directories). A single configuration file:

- Reduces configuration duplication
- Ensures consistent security boundaries
- Simplifies maintenance

## Why Validate Container State?

Attempting to extract from a stopped container would fail silently or with cryptic errors. Explicit state validation provides clear error messages and appropriate exit codes for backup monitoring.

# Related Files

| File                                     | Purpose                                   |
|------------------------------------------|-------------------------------------------|
| `/usr/local/sbin/backuppc-staging-cleanup` | Clean staging before extraction           |
| `/usr/local/sbin/tarCreate`                | BackupPC's privileged tar create wrapper  |
| `/usr/local/sbin/tarRestore`               | BackupPC's privileged tar restore wrapper |
| `/usr/local/lib/backuppc/common.sh`        | Shared functions library                  |
| `/etc/backuppc/staging.conf`               | Unified staging allowlist                 |

# Troubleshooting

## "Config file not found"

- Ensure `/etc/backuppc/staging.conf` exists
- Check path if using `STAGING_CONFIG` override

## "must be owned by root:root"

- Run: `sudo chown root:root /etc/backuppc/staging.conf`

## "not under any allowed root"

- Add the parent directory to `staging.conf`
- Note: staging dir must be *under* a root, not equal to it

## "Container does not exist"

- Verify container name: `incus list`
- Check for typos in container name

## "Container is not running"

- Start container: `incus start <container>`
- Or check why it stopped: `incus info <container>`

## "Path does not exist in container"

- Verify path exists: `incus exec <container> -- ls -la /<path>`
- Remember: paths must be relative (no leading `/`)

## "sudo: tarRestore: command not found"

- Ensure tarRestore is in sudoers for backuppc user
- Check path: default is `/usr/local/sbin/tarRestore`
