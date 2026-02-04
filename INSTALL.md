# Installation Guide

Complete deployment guide for the BackupPC Services Backup Suite.

## Prerequisites

### System Requirements

| Component | Minimum Version | Notes |
|-----------|-----------------|-------|
| Bash | 4.x | Required for associative arrays, `${!var}` syntax |
| BackupPC | 4.x | Tested with 4.4.0 |
| Incus | 5.x | Or LXD 5.x (adjust commands accordingly) |
| MariaDB Client | 10.5+ | `mariadb-admin`, `mariadb-dump` |

### Required Packages

**Arch Linux / Manjaro:**
```bash
sudo pacman -S util-linux coreutils zstd incus mariadb-clients
```

**Debian / Ubuntu:**
```bash
sudo apt install util-linux coreutils zstd incus mariadb-client
```

**RHEL / CentOS / Rocky:**
```bash
sudo dnf install util-linux coreutils zstd mariadb
# Incus requires additional repository setup
```

### Verify Dependencies

```bash
# Core utilities
command -v flock findmnt logger realpath mktemp sha256sum

# Application tools
command -v zstd incus mariadb-admin mariadb-dump

# Bash version
bash --version | head -1
```

## Directory Layout

The suite installs to standard FHS locations:

| Source | Destination | Purpose |
|--------|-------------|---------|
| `lib/backuppc/common.sh` | `/usr/local/lib/backuppc/common.sh` | Shared library |
| `bin/*` | `/usr/local/sbin/` | Privileged helpers |
| `svc/*` | `/usr/local/sbin/` | Service scripts |
| `etc/backuppc/*` | `/etc/backuppc/` | Configuration |
| `var/lib/backuppc/` | `/var/lib/backuppc/` | Runtime data |

## Installation Steps

### 1. Create Directories

```bash
sudo mkdir -p /usr/local/lib/backuppc
sudo mkdir -p /etc/backuppc
sudo mkdir -p /var/log/backuppc
sudo mkdir -p /srv/backuppc/services
```

### 2. Install Library

```bash
sudo install -m 644 lib/backuppc/common.sh /usr/local/lib/backuppc/
```

### 3. Install Privileged Helpers

These require root execution via sudo:

```bash
# Staging cleanup helper
sudo install -m 755 bin/backuppc-staging-cleanup /usr/local/sbin/

# Container extraction helper  
sudo install -m 755 bin/backuppc-staging-extract /usr/local/sbin/

# Tar wrappers (if not already installed by BackupPC)
# sudo install -m 755 bin/tarCreate /usr/local/sbin/
# sudo install -m 755 bin/tarRestore /usr/local/sbin/
```

### 4. Install Service Scripts

```bash
# Nextcloud service
sudo install -m 755 svc/backuppc-svc-nextcloud-pre /usr/local/sbin/
sudo install -m 755 svc/backuppc-svc-nextcloud-post /usr/local/sbin/

# MariaDB service
sudo install -m 755 svc/backuppc-svc-mariadb-pre /usr/local/sbin/
sudo install -m 755 svc/backuppc-svc-mariadb-post /usr/local/sbin/
```

### 5. Install Configuration

```bash
# Staging roots configuration
sudo install -m 644 etc/backuppc/staging.conf /etc/backuppc/

# MariaDB credentials template (customize before use)
sudo install -m 640 -o backuppc -g backuppc etc/backuppc/mysql-backupmeta.cnf /etc/backuppc/
```

### 6. Set Ownership

```bash
sudo chown -R root:root /usr/local/lib/backuppc
sudo chown -R root:root /usr/local/sbin/backuppc-*
sudo chown root:root /etc/backuppc/staging.conf
sudo chown backuppc:backuppc /var/log/backuppc
```

## Sudoers Configuration

The backuppc user needs specific sudo privileges. Create `/etc/sudoers.d/backuppc`:

```bash
sudo visudo -f /etc/sudoers.d/backuppc
```

Add the following:

```sudoers
# BackupPC Services Backup Suite - Sudoers Configuration
# /etc/sudoers.d/backuppc

# Privileged helpers
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/backuppc-staging-cleanup
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/backuppc-staging-extract

# Tar operations (ownership preservation)
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarCreate
backuppc ALL=(root) NOPASSWD: /usr/local/sbin/tarRestore

# Bind mount operations
backuppc ALL=(root) NOPASSWD: /usr/bin/mount --bind *
backuppc ALL=(root) NOPASSWD: /usr/bin/umount /srv/backuppc/*
backuppc ALL=(root) NOPASSWD: /usr/bin/umount /srv/backuppc-staging/*
```

**Security Notes:**
- Helpers validate paths against `/etc/backuppc/staging.conf`
- Mount operations are restricted to backup-related paths
- Wildcards are intentionally limited in scope

Verify configuration:
```bash
sudo visudo -c -f /etc/sudoers.d/backuppc
```

## Staging Configuration

Edit `/etc/backuppc/staging.conf` to define allowed staging roots:

```bash
# /etc/backuppc/staging.conf
# One directory per line. Comments start with #.

# Default BackupPC staging area
/srv/backuppc-staging

# Service-specific staging roots
/export/mariadb/backuppc
```

**Security Requirements:**
- File must be owned by `root:root`
- Mode must be 644 or stricter (no group/other write)
- Paths must be absolute
- Helpers validate against this allowlist

## Database User Configuration

### Service Database User (BackupOp)

For dumping service databases (Nextcloud, Digikam, etc.):

```sql
-- On your MariaDB server
CREATE USER 'BackupOp'@'<backuppc-host>' IDENTIFIED BY 'secure-password';

-- Per-service grants (minimal privileges)
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER 
    ON nextcloud.* TO 'BackupOp'@'<backuppc-host>';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER 
    ON digikam.* TO 'BackupOp'@'<backuppc-host>';

FLUSH PRIVILEGES;
```

### Instance Metadata User (BackupMeta)

For mysql.* dumps and binary log management:

```sql
CREATE USER 'BackupMeta'@'<backuppc-host>' IDENTIFIED BY 'secure-password';

-- Instance-level privileges
GRANT RELOAD, PROCESS, BINLOG MONITOR ON *.* TO 'BackupMeta'@'<backuppc-host>';
GRANT SELECT, SHOW VIEW ON mysql.* TO 'BackupMeta'@'<backuppc-host>';

FLUSH PRIVILEGES;
```

### Credentials File

Create `/etc/backuppc/mysql-backupmeta.cnf`:

```ini
[client]
host = minerva.nepomuc.de
user = BackupMeta
password = secure-password

# Optional: require SSL
ssl-mode = REQUIRED
```

Set permissions:
```bash
sudo chown backuppc:backuppc /etc/backuppc/mysql-backupmeta.cnf
sudo chmod 600 /etc/backuppc/mysql-backupmeta.cnf
```

Create similar files for other database users as needed.

## BackupPC Configuration

### Host Configuration

For each service host, edit `/etc/backuppc/<hostname>.pl`:

```perl
# Nextcloud Service Backup
$Conf{XferMethod} = 'rsync';
$Conf{RsyncShareName} = ['/srv/backuppc/services/nextcloud'];

# Pre-backup: prepare staging (maintenance mode, dump database, extract config)
$Conf{DumpPreUserCmd} = '/usr/local/sbin/backuppc-svc-nextcloud-pre';

# Post-backup: validate artifacts, record status, cleanup
$Conf{DumpPostUserCmd} = '/usr/local/sbin/backuppc-svc-nextcloud-post $cmdType $xferOK';

# Backup schedule
$Conf{FullPeriod} = 6.97;    # Weekly full
$Conf{IncrPeriod} = 0.97;    # Daily incremental

# Exclude metadata (changes every run)
$Conf{BackupFilesExclude} = {
    '/srv/backuppc/services/nextcloud' => ['/meta'],
};
```

### MariaDB Instance Backup

```perl
# MariaDB Instance Backup (weekly)
$Conf{XferMethod} = 'rsync';
$Conf{RsyncShareName} = ['/srv/backuppc/services/mariadb'];

$Conf{DumpPreUserCmd} = '/usr/local/sbin/backuppc-svc-mariadb-pre';
$Conf{DumpPostUserCmd} = '/usr/local/sbin/backuppc-svc-mariadb-post $cmdType $xferOK';

$Conf{FullPeriod} = 6.97;    # Weekly
$Conf{IncrPeriod} = -1;      # No incrementals (full only)
```

## Staging Directory Setup

### Create Directory Structure

```bash
# Main staging area (on fast storage)
sudo mkdir -p /export/mariadb/backuppc/services

# BackupPC view mount point
sudo mkdir -p /srv/backuppc/services

# Set ownership
sudo chown -R backuppc:backuppc /export/mariadb/backuppc
sudo chown backuppc:backuppc /srv/backuppc/services
```

### Optional: Systemd Mount Unit

For automatic bind mount on boot:

```ini
# /etc/systemd/system/srv-backuppc-services.mount
[Unit]
Description=BackupPC Services Staging Bind Mount
After=local-fs.target
Requires=export-mariadb.mount

[Mount]
What=/export/mariadb/backuppc/services
Where=/srv/backuppc/services
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now srv-backuppc-services.mount
```

**Note:** The pre-backup scripts create this mount dynamically if not present, so the systemd unit is optional.

## Verification

### 1. Test Library Loading

```bash
sudo -u backuppc bash -c '
    source /usr/local/lib/backuppc/common.sh
    echo "Library loaded successfully"
    echo "SCRIPT_NAME: $SCRIPT_NAME"
'
```

### 2. Test Sudo Access

```bash
sudo -u backuppc sudo -n /usr/local/sbin/backuppc-staging-cleanup --help
sudo -u backuppc sudo -n /usr/bin/mount --bind /tmp /tmp 2>&1 | head -1
```

### 3. Test Container Access

```bash
sudo -u backuppc incus list
sudo -u backuppc incus exec nextcloud-server -- true && echo "Container accessible"
```

### 4. Test Database Connectivity

```bash
sudo -u backuppc mariadb-admin ping -h minerva.nepomuc.de
```

### 5. Dry Run Pre-Script

```bash
# Run manually to verify before BackupPC invocation
sudo -u backuppc DEBUG=1 /usr/local/sbin/backuppc-svc-nextcloud-pre
```

### 6. Run Test Suite

```bash
cd /path/to/backuppc-services
./tests/test-common.sh
./tests/test-staging-cleanup.sh
./tests/test-staging-extract.sh
```

## Troubleshooting

### Common Issues

**Lock acquisition failed:**
```
[ERROR] Another instance is running (lock held: /var/log/backuppc/LOCK.backuppc-svc-nextcloud-pre)
```
- Check for stale lock files: `ls -la /var/log/backuppc/LOCK.*`
- Remove stale locks: `sudo rm /var/log/backuppc/LOCK.<script>`

**Permission denied on staging:**
```
[ERROR] Failed to cleanup staging directory
```
- Verify sudoers configuration
- Check staging.conf includes the path
- Verify staging.conf ownership: `ls -la /etc/backuppc/staging.conf`

**Container not running:**
```
[ERROR] Container is not running: nextcloud-server
```
- Check container status: `incus list`
- Start container: `incus start nextcloud-server`

**Database unreachable:**
```
[ERROR] Database host minerva.nepomuc.de not reachable
```
- Verify network connectivity
- Check MariaDB credentials file
- Test manually: `mariadb -h minerva.nepomuc.de -u BackupOp -p`

### Log Locations

| Log | Location |
|-----|----------|
| Script logs | `/var/log/backuppc/LOG.<script-name>` |
| Syslog | `/var/log/syslog` or `journalctl -t backuppc/*` |
| BackupPC logs | `/var/lib/backuppc/pc/<host>/LOG` |

### Debug Mode

Enable verbose logging:
```bash
DEBUG=1 /usr/local/sbin/backuppc-svc-nextcloud-pre
```

## Uninstallation

```bash
# Remove scripts
sudo rm -f /usr/local/sbin/backuppc-svc-*
sudo rm -f /usr/local/sbin/backuppc-staging-*

# Remove library
sudo rm -rf /usr/local/lib/backuppc

# Remove configuration (optional - preserves customization)
# sudo rm -f /etc/backuppc/staging.conf
# sudo rm -f /etc/backuppc/mysql-*.cnf

# Remove sudoers
sudo rm -f /etc/sudoers.d/backuppc

# Remove logs (optional)
# sudo rm -f /var/log/backuppc/LOG.backuppc-*
# sudo rm -f /var/log/backuppc/LOCK.backuppc-*
```

## Upgrading

1. Stop any running backups
2. Backup existing configuration: `cp -a /etc/backuppc /etc/backuppc.bak`
3. Install new files (overwrite scripts and library)
4. Review configuration for new options
5. Run test suite
6. Resume backups
