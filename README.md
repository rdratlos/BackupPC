# BackupPC Services Backup Suite

Extend BackupPC with service-centric backup capabilities for containerized applications.

## Overview

This suite extends [BackupPC](https://backuppc.github.io/backuppc/) beyond traditional host/VM backups to provide **application-consistent service backups**. It captures not just files, but complete service state including database dumps, configuration, package lists, and metadata—everything needed for disaster recovery.

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                        BackupPC Services Architecture                         │
├───────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│   BackupPC Server          Staging Layer              Containers/Services     │
│   ───────────────          ─────────────              ──────────────────      │
│                                                                               │
│   ┌─────────────┐     ┌─────────────────────┐     ┌─────────────────────────┐ │
│   │  BackupPC   │◀───│ /srv/backuppc/      │◀───│  Incus Containers       │ │
│   │   Daemon    │     │  services/          │     │  ┌─────────────────────┐│ │
│   │             │     │  ├─nextcloud/       │     │  │ nextcloud-server    ││ │
│   │  rsync/tar  │     │  │ ├─config/        │◀───│──│ • /etc              ││ │
│   │  pooling    │     │  │ ├─db/            │     │  │ • occ status        ││ │
│   └─────────────┘     │  │ └─meta/          │     │  └─────────────────────┘│ │
│         │             │  └─mariadb/         │     │  ┌─────────────────────┐│ │
│         │             │    ├─server/        │◀───│──│ minerva (MariaDB)   ││ │
│         ▼             │    │ └─db/binlogs   │     │  │ • mysql.* dump      ││ │
│   DumpPreUserCmd      │    └─meta/          │     │  │ • binary logs       ││ │
│   DumpPostUserCmd     └─────────────────────┘     │  └─────────────────────┘│ │
│                                 ▲                 └─────────────────────────┘ │
│                                 │                                             │
│                             Bind Mount                                        │
│                    /export/mariadb/backuppc/services                          │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

## Key Features

- **Application-consistent backups** — Database dumps with `--single-transaction`, maintenance mode during backup
- **Complete disaster recovery** — Configuration, package lists, systemd units, metadata
- **Privilege separation** — Unprivileged scripts with sudo helpers for specific operations
- **Robust error handling** — Strict bash mode, phase tracking, registered cleanup actions
- **Comprehensive logging** — Syslog integration, per-script log files, stderr capture
- **Bind mount management** — Safe mount/unmount with source verification using `findmnt`
- **Container support** — Native Incus integration with ownership-preserving extraction

## Quick Start

```bash
# 1. Install the suite (see INSTALL.md for details)
sudo ./install.sh

# 2. Configure sudoers (see INSTALL.md)
sudo visudo -f /etc/sudoers.d/backuppc

# 3. Add staging roots to configuration
echo "/export/mariadb/backuppc" | sudo tee -a /etc/backuppc/staging.conf

# 4. Configure BackupPC host
# In /etc/backuppc/<hostname>.pl:
$Conf{DumpPreUserCmd} = '/usr/local/sbin/backuppc-svc-nextcloud-pre';
$Conf{DumpPostUserCmd} = '/usr/local/sbin/backuppc-svc-nextcloud-post $cmdType $xferOK';
```

## Repository Structure

```
backuppc-services/
├── bin/                          # Privileged helper scripts
│   ├── backuppc-staging-extract  # Extract from containers preserving ownership
│   └── backuppc-staging-cleanup  # Safe staging directory cleanup
├── lib/
│   ├── backuppc/
│   │   └── common.sh             # Shared library (1300+ lines)
│   └── mariadb/                  # MariaDB-specific helpers
├── svc/                          # Service backup scripts
│   ├── backuppc-svc-nextcloud-pre
│   ├── backuppc-svc-nextcloud-post
│   ├── backuppc-svc-mariadb-pre
│   └── backuppc-svc-mariadb-post
├── etc/backuppc/                 # Configuration templates
│   ├── staging.conf              # Allowed staging roots
│   └── mysql-backupmeta.cnf      # MariaDB credentials template
├── docs/                         # Documentation
│   ├── Shared Library Reference.md
│   ├── BackupPC Staging Extract Helper.md
│   ├── BackupPC Staging Cleanup Helper.md
│   └── templates/                # Script templates for new services
├── tests/                        # Test suite
│   ├── test-common.sh
│   ├── test-staging-extract.sh
│   ├── test-staging-cleanup.sh
│   └── test-failure.sh
├── var/lib/backuppc/             # Runtime data templates
├── README.md                     # This file
├── INSTALL.md                    # Deployment guide
└── LICENSE                       # AGPL-3.0
```

## Implemented Services

| Service | Pre-Script | Post-Script | Features |
|---------|-----------|-------------|----------|
| **Nextcloud** | `backuppc-svc-nextcloud-pre` | `backuppc-svc-nextcloud-post` | Maintenance mode, database dump, app list, config extraction |
| **MariaDB** | `backuppc-svc-mariadb-pre` | `backuppc-svc-mariadb-post` | Binary log flush, mysql.* dump, PITR support, grant export |

## Staging Structure

Each service creates a standardized staging directory:

```
/export/mariadb/backuppc/services/<service>/
├── config/           # Extracted /etc (ownership preserved)
├── db/               # Database dumps (.sql.zst + .sha256)
├── app/              # Application state (occ status, etc.)
├── app-list/         # Application inventory
├── package-list/     # pkglist-repo.txt, pkglist-aur.txt, pkg-versions.txt
├── systemd-list/     # systemd-enabled.txt
└── meta/             # run_id, started_at, container, xferOK, status
```

## Documentation

| Document | Description |
|----------|-------------|
| [INSTALL.md](INSTALL.md) | Deployment guide, sudoers setup, dependencies |
| [docs/Shared Library Reference.md](docs/Shared%20Library%20Reference.md) | Complete common.sh API documentation |
| [docs/BackupPC Staging Extract Helper.md](docs/BackupPC%20Staging%20Extract%20Helper.md) | Container extraction helper |
| [docs/BackupPC Staging Cleanup Helper.md](docs/BackupPC%20Staging%20Cleanup%20Helper.md) | Staging cleanup helper |
| [docs/templates/](docs/templates/) | Templates for creating new service scripts |

## Creating a New Service

1. Copy the template: `cp docs/templates/backuppc-svc-example-pre svc/backuppc-svc-myservice-pre`
2. Search for `<` to find customization points
3. Define container, staging paths, and extraction paths
4. Implement service-specific functions (maintenance mode, database dump, etc.)
5. Create the corresponding post-script from the post template
6. Add tests to `tests/`

See [docs/templates/backuppc-svc-example-pre](docs/templates/backuppc-svc-example-pre) for detailed guidance.

## Exit Codes

### Library Reserved (0-29)

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Configuration/validation error |
| 3 | Staging operation failed |
| 4 | Container operation failed |
| 5 | Timeout / temp file error |
| 10 | Lock acquisition failed |
| 20 | Mount verification failed |

### Service-Specific (30-99)

| Range | Category |
|-------|----------|
| 30-39 | Database errors |
| 40-49 | Service validation |
| 50-59 | Extraction/transfer |
| 60-69 | Post-backup validation |

## Requirements

- **Bash 4.x+**
- **BackupPC 4.x**
- **util-linux** (flock, findmnt, logger)
- **coreutils** (realpath, mktemp, sha256sum)
- **zstd** (compression)
- **Incus** (container management)
- **MariaDB client** (mariadb-admin, mariadb-dump) — for database services

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).

See [LICENSE](LICENSE) for the full license text.

## Contributing

1. Follow the existing code style (see common.sh for patterns)
2. Use strict bash mode (`set -euo pipefail`)
3. Add phase tracking for error context
4. Write tests for new functionality
5. Document exit codes and cleanup behavior

## Related Projects

- [BackupPC](https://backuppc.github.io/backuppc/) — The backup system this extends
- [Incus](https://linuxcontainers.org/incus/) — Container management

---

*Developed with assistance from Claude (Anthropic) through iterative design and testing.*
