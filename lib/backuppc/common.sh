#!/bin/bash
# =============================================================================
# /usr/local/lib/backuppc/common.sh - Shared functions for BackupPC scripts
# =============================================================================
#
# Purpose:
#   Foundation library sourced by BackupPC service scripts (pre/post backup
#   hooks, staging helpers, etc.). Provides logging, locking, error handling,
#   and common operations.
#
# Usage:
#   #!/bin/bash
#   source /usr/local/lib/backuppc/common.sh
#   # SCRIPT_NAME auto-detected, or override before sourcing
#
# Dependencies:
#   - bash 4.x+
#   - flock (util-linux)
#   - logger (util-linux)
#   - findmnt (util-linux)
#   - realpath (coreutils)
#   - mktemp (coreutils)
#   - zstd (for artifact validation)
#   - sha256sum (coreutils)
#   - incus (for container operations)
#   - pacman (for container package captures, Arch/Manjaro only)
#   - sudo access to mount, umount, tarCreate, tarRestore, backuppc-staging-cleanup
#
# File locations:
#   Logs:  /var/log/backuppc/LOG.${SCRIPT_NAME}
#   Locks: /var/log/backuppc/LOCK.${SCRIPT_NAME}
#
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode
# -----------------------------------------------------------------------------
set -o errexit      # Exit on error
set -o nounset      # Error on unset variables
set -o pipefail     # Pipeline fails on first error
set -o errtrace     # ERR trap inherited by functions/subshells

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly BACKUPPC_LOG_DIR="/var/log/backuppc"
readonly BACKUPPC_LIB_DIR="/usr/local/lib/backuppc"
readonly BACKUPPC_SBIN_DIR="/usr/local/sbin"

# -----------------------------------------------------------------------------
# Environment setup
# -----------------------------------------------------------------------------
# BackupPC runs scripts with minimal PATH (often just /bin).
# Ensure standard system paths are available for our tools.
# We prepend to preserve any existing PATH entries.

_BACKUPPC_REQUIRED_PATHS="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Only add paths not already present
for _path in ${_BACKUPPC_REQUIRED_PATHS//:/ }; do
    case ":${PATH}:" in
        *":${_path}:"*) ;;  # Already in PATH
        *) PATH="${_path}:${PATH}" ;;
    esac
done
unset _path _BACKUPPC_REQUIRED_PATHS
export PATH

# Script identification (caller may override SCRIPT_NAME before sourcing)
: "${SCRIPT_NAME:=$(basename "${BASH_SOURCE[-1]}" 2>/dev/null || basename "$0")}"
readonly SCRIPT_NAME

# Derived paths
readonly LOG_FILE="${BACKUPPC_LOG_DIR}/LOG.${SCRIPT_NAME}"
readonly LOCK_FILE="${BACKUPPC_LOG_DIR}/LOCK.${SCRIPT_NAME}"

# Syslog tag for logger
readonly LOG_TAG="backuppc/${SCRIPT_NAME}"

# Lock file descriptor (global, used by acquire_lock/release_lock)
declare -g LOCK_FD=""

# Cleanup trap registry
declare -ga _CLEANUP_ACTIONS=()

# -----------------------------------------------------------------------------
# Logging functions
# -----------------------------------------------------------------------------
# All logging goes to:
#   1. Syslog (via logger) for centralized logging
#   2. Script-specific log file for BackupPC-style per-script logs
#   3. stdout/stderr for immediate feedback (and BackupPC capture)
#
# Format: YYYY-MM-DD HH:MM:SS [LEVEL] message

_log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"
    local formatted="[${timestamp}] [${level}] ${message}"

    # Syslog (background, don't fail script if logger unavailable)
    case "$level" in
        INFO)  logger -t "$LOG_TAG" -p user.info  -- "$message" 2>/dev/null || true ;;
        WARN)  logger -t "$LOG_TAG" -p user.warning -- "$message" 2>/dev/null || true ;;
        ERROR) logger -t "$LOG_TAG" -p user.err   -- "$message" 2>/dev/null || true ;;
        DEBUG) logger -t "$LOG_TAG" -p user.debug -- "$message" 2>/dev/null || true ;;
    esac

    # Log file (append, create if missing)
    if [[ -d "$BACKUPPC_LOG_DIR" ]]; then
        echo "$formatted" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Console output (all to stderr)
    echo "$formatted" >&2
}

log()   { _log INFO  "$@"; }
warn()  { _log WARN  "$@"; }
error() { _log ERROR "$@"; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && _log DEBUG "$@" || true; }

# -----------------------------------------------------------------------------
# Phase tracking and failure state
# -----------------------------------------------------------------------------
# Scripts can set PHASE to track where they are in execution.
# Failure state is captured for use in exit handlers.
#
# Usage:
#   PHASE="extracting config"
#   extract_container_path ...
#   PHASE="database dump"
#   run_dump ...

# Human-readable phase marker for logs
declare -g PHASE="init"

# Failure state (captured by fail() and on_err trap)
declare -g FAILED=0
declare -g FAIL_RC=0
declare -g FAIL_MSG=""
declare -g FAIL_PHASE=""
declare -g FAIL_LINE=""
declare -g FAIL_CMD=""

# -----------------------------------------------------------------------------
# Error handling
# -----------------------------------------------------------------------------
# fail: Mark failure state and exit
# Usage: fail <exit_code> <message>
#
# Captures current phase and sets global failure state before exiting.
# The on_exit handler can then perform appropriate cleanup.

fail() {
    local rc="${1:-1}"
    shift
    local msg="$*"

    # Only capture first failure (subsequent calls during cleanup are logged but don't override)
    if [[ "$FAILED" -eq 0 ]]; then
        FAILED=1
        FAIL_RC="$rc"
        FAIL_MSG="$msg"
        FAIL_PHASE="$PHASE"
        FAIL_LINE="${BASH_LINENO[0]:-unknown}"
        FAIL_CMD="${BASH_COMMAND:-unknown}"
    fi

    error "FATAL: phase=${PHASE} rc=${rc} msg=${msg}"
    exit "$rc"
}

# die: Shorthand for fail with exit code 1
die() {
    fail 1 "$@"
}

# -----------------------------------------------------------------------------
# Trap handlers
# -----------------------------------------------------------------------------
# on_err: ERR trap handler - captures unexpected errors and exits
# Triggered by set -o errexit when a command fails.
#
# Note: To enable, scripts must call: trap 'on_err' ERR
#       Or use: enable_strict_traps

on_err() {
    local rc=$?

    # Capture failure details (only first failure)
    if [[ "$FAILED" -eq 0 ]]; then
        FAILED=1
        FAIL_RC="$rc"
        FAIL_PHASE="$PHASE"
        FAIL_LINE="${BASH_LINENO[0]:-unknown}"
        FAIL_CMD="${BASH_COMMAND:-unknown}"
        FAIL_MSG="command failed: ${FAIL_CMD}"
        error "Unexpected error: phase=${FAIL_PHASE} rc=${rc} line=${FAIL_LINE} cmd=${FAIL_CMD}"
    fi

    # Exit immediately - cleanup will run via EXIT trap
    # Note: We exit with the error code, EXIT trap will handle reporting
    exit "$rc"
}

# on_exit: EXIT trap handler - runs cleanup and reports final status
# This is the main exit handler that:
#   1. Disables ERR trap (cleanup errors shouldn't abort remaining cleanup)
#   2. Runs registered cleanup actions
#   3. Reports success/failure with context
#   4. Exits with appropriate code
#
# Note: Automatically installed by enable_strict_traps or can be
#       manually set with: trap 'on_exit' EXIT

on_exit() {
    local rc=$?

    # Disable ERR trap during cleanup - we don't want cleanup errors
    # to trigger on_err (which would call exit and skip remaining cleanup)
    trap - ERR

    # If we're exiting due to a failure, use the captured code
    # Otherwise use the actual exit code
    local final_rc="$rc"
    if [[ "$FAILED" -ne 0 ]]; then
        final_rc="$FAIL_RC"
    fi

    # Run registered cleanup actions (in reverse order)
    _run_cleanup_actions

    # Final status report
    if [[ "$FAILED" -ne 0 ]]; then
        error "Script failed: phase=${FAIL_PHASE:-unknown} rc=${FAIL_RC} msg=${FAIL_MSG:-unknown error}"
        error "==== ${SCRIPT_NAME} FAILED ===="
        exit "$final_rc"
    fi

    log "==== ${SCRIPT_NAME} completed successfully ===="
    exit "$final_rc"
}

# enable_strict_traps: Install ERR and EXIT traps for comprehensive error handling
# Call this early in your script after sourcing common.sh
#
# Usage:
#   source /usr/local/lib/backuppc/common.sh
#   enable_strict_traps
#
# This enables:
#   - ERR trap: Captures unexpected command failures
#   - EXIT trap: Ensures cleanup runs and reports final status

enable_strict_traps() {
    trap 'on_err' ERR
    trap 'on_exit' EXIT
    debug "Strict traps enabled (ERR + EXIT)"
}

# get_failure_summary: Return a structured summary of the failure
# Useful for external reporting or notification scripts
get_failure_summary() {
    if [[ "$FAILED" -eq 0 ]]; then
        echo "status=success"
    else
        cat <<EOF
status=failed
phase=${FAIL_PHASE:-unknown}
rc=${FAIL_RC:-1}
line=${FAIL_LINE:-unknown}
cmd=${FAIL_CMD:-unknown}
msg=${FAIL_MSG:-unknown}
EOF
    fi
}

# -----------------------------------------------------------------------------
# Lock management
# -----------------------------------------------------------------------------
# Uses flock for advisory locking. Lock files stored alongside BackupPC's
# main LOCK file in /var/log/backuppc.
#
# Usage:
#   acquire_lock [name]   # name defaults to SCRIPT_NAME
#   release_lock          # automatic on exit if trap registered

acquire_lock() {
    local lock_name="${1:-$SCRIPT_NAME}"
    local lockfile="${BACKUPPC_LOG_DIR}/LOCK.${lock_name}"

    # Ensure lock directory exists and is writable
    if [[ ! -d "$BACKUPPC_LOG_DIR" ]]; then
        fail 10 "Lock directory does not exist: $BACKUPPC_LOG_DIR"
    fi

    if [[ ! -w "$BACKUPPC_LOG_DIR" ]]; then
        fail 10 "Lock directory not writable: $BACKUPPC_LOG_DIR"
    fi

    # Open lock file on next available FD
    exec {LOCK_FD}>"$lockfile" || fail 10 "Cannot open lock file: $lockfile"

    # Attempt non-blocking lock
    if ! flock -n "$LOCK_FD"; then
        fail 10 "Another instance is running (lock held: $lockfile)"
    fi

    # Write PID for debugging
    echo "$$" >&"$LOCK_FD"

    log "Lock acquired: $lockfile (PID $$)"

    # Register cleanup if not already done
    register_cleanup "release_lock"
}

release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
        LOCK_FD=""
        debug "Lock released"
    fi
}

# -----------------------------------------------------------------------------
# Cleanup action management
# -----------------------------------------------------------------------------
# Register cleanup actions that run on script exit (via on_exit trap).
# Actions run in reverse order of registration (LIFO).
#
# Usage:
#   register_cleanup "rm -f /tmp/myfile"
#   register_cleanup "cleanup_function arg1 arg2"
#
# Note: Cleanup actions run even on failure. Check $FAILED inside
#       cleanup functions if you need conditional behavior.

register_cleanup() {
    local action="$1"
    _CLEANUP_ACTIONS+=("$action")
    debug "Registered cleanup action: $action"
}

# Internal: Run all registered cleanup actions
# Called by on_exit trap handler
_run_cleanup_actions() {
    local i
    local action
    local cleanup_errors=0

    if [[ ${#_CLEANUP_ACTIONS[@]} -eq 0 ]]; then
        return 0
    fi

    debug "Running ${#_CLEANUP_ACTIONS[@]} cleanup actions"

    # Run in reverse order (LIFO)
    for ((i=${#_CLEANUP_ACTIONS[@]}-1; i>=0; i--)); do
        action="${_CLEANUP_ACTIONS[i]}"
        debug "Cleanup: $action"

        # Run cleanup, capture errors but don't abort
        if ! eval "$action" 2>/dev/null; then
            warn "Cleanup action failed: $action"
            cleanup_errors=$((cleanup_errors + 1))
        fi
    done

    if [[ $cleanup_errors -gt 0 ]]; then
        warn "Some cleanup actions failed ($cleanup_errors errors)"
    fi
}

# -----------------------------------------------------------------------------
# Staging directory operations
# -----------------------------------------------------------------------------
# Wrappers for staging directory management, using privileged helpers
# when needed.

# cleanup_staging: Remove contents of staging directory safely
# Uses the jailed cleanup helper via sudo
cleanup_staging() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        fail 2 "cleanup_staging: directory argument required"
    fi

    log "Cleaning staging directory: $dir"
    sudo "${BACKUPPC_SBIN_DIR}/backuppc-staging-cleanup" "$dir" \
        || fail 3 "Failed to cleanup staging directory: $dir"
}

# ensure_staging_dir: Create staging directory structure
# Creates directory with proper ownership for backuppc user
ensure_staging_dir() {
    local dir="$1"
    local mode="${2:-0755}"

    if [[ -z "$dir" ]]; then
        fail 2 "ensure_staging_dir: directory argument required"
    fi

    if [[ ! -d "$dir" ]]; then
        log "Creating staging directory: $dir"
        mkdir -p "$dir" || fail 3 "Failed to create directory: $dir"
        chmod "$mode" "$dir" || warn "Failed to set mode $mode on $dir"
    fi
}

# -----------------------------------------------------------------------------
# BIND MOUNT VERIFICATION AND CREATION
# -----------------------------------------------------------------------------
# This function ensures DEST is bind-mounted from exactly SOURCE.
#
# How it works:
#   findmnt shows bind mounts to subdirectories as: device[/subpath]
#   We construct this string from SOURCE and compare against DEST.
#
# What it catches:
#   - DEST mounted from wrong directory
#   - DEST mounted from wrong filesystem
#   - DEST is a regular mount, not a bind mount (for subdirectory sources)
#
# Exit codes:
#   0  - Bind mount correctly in place (existing or newly created)
#   20 - Mount verification failed
ensure_bind_mount() {
  local src="${1:-}" dst="${2:-}"

  # Validate parameters
  if [[ -z "$src" || -z "$dst" ]]; then
    fail 2 "ensure_bind_mount: requires <src_path> <dest_path>"
  fi

  # Create directories if needed
  if ! mkdir -p -- "$src" "$dst"; then
    fail 3 "Failed to create directories: $src and/or $dst"
  fi

  # Resolve symlinks for consistent comparison
  local src_resolved="" dst_resolved=""
  src_resolved=$(realpath "$src" 2>/dev/null) || true
  dst_resolved=$(realpath "$dst" 2>/dev/null) || true

  if [[ -z "$src_resolved" || ! -d "$src_resolved" ]]; then
    fail 20 "Source not accessible: $src"
  fi

  if [[ -z "$dst_resolved" || ! -d "$dst_resolved" ]]; then
    fail 20 "Destination not accessible: $dst"
  fi

  # Check if DEST is currently mounted
  local actual=""
  actual=$(findmnt -n -o SOURCE --mountpoint "$dst_resolved" 2>/dev/null) || true

  if [[ -z "$actual" ]]; then
    # Not mounted — create the bind mount
    log "Creating bind mount: $src -> $dst"
    if ! sudo /usr/bin/mount --bind "$src" "$dst"; then
      fail 20 "Failed to create bind mount: $src -> $dst"
    fi
    log "Bind mount created successfully"
    return 0
  fi

  # DEST is mounted — verify it's from exactly SOURCE
  # Walk up SOURCE to find its actual mount point
  local path="$src_resolved"
  local src_device="" src_mountpoint=""
  while [[ -n "$path" ]]; do
    src_device=$(findmnt -n -o SOURCE --mountpoint "$path" 2>/dev/null) || true
    if [[ -n "$src_device" ]]; then
      src_mountpoint="$path"
      break
    fi
    path="${path%/*}"
  done

  if [[ -z "$src_device" ]]; then
    error "Could not determine mount point for source: $src"
    error "Is the underlying filesystem mounted?"
    fail 20 "Failed to verify bind mount: $src -> $dst"
  fi

  # Calculate relative path and build expected SOURCE string
  local relative="${src_resolved#$src_mountpoint}"
  local expected=""
  if [[ -n "$relative" ]]; then
    expected="${src_device}[${relative}]"
  else
    expected="$src_device"
  fi

  # Compare
  if [[ "$actual" == "$expected" ]]; then
    log "Bind mount already present: $src -> $dst"
    return 0
  fi

  # Mismatch — report details and fail
  error "$dst is already a mountpoint, but not our expected bind mount."
  error "expected source: $expected"
  error "actual source:   $actual"
  error "findmnt output:"
  error "  $(findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS --target "$dst_resolved" 2>/dev/null || echo 'n/a')"
  fail 20 "Wrong source mounted to $dst"
}

# remove_bind_mount: Unmount a bind mount destination
# Usage: remove_bind_mount <dest_path>
#
# Unmounts DEST only if it is a direct mount point.
# If DEST is accessible via parent mount, leave it alone (not our responsibility).
# If mount is busy, logs warning and returns success (intentional for failure investigation).
#
# Design note: This function intentionally does NOT fail the script on errors.
# Post-backup scripts should complete cleanup as much as possible, and a busy
# mount may be intentional (e.g., for investigating a failed backup).
#
# Exit codes:
#   0  - Always returns 0 (mount cleaned up, not a direct mount, busy, or error)
remove_bind_mount() {
    local dst="${1:-}"

    if [[ -z "$dst" ]]; then
        error "remove_bind_mount: requires <dest_path>"
        return 0  # Don't fail the whole post-script for parameter error
    fi

    # Resolve symlinks for consistent handling
    local dst_resolved=""
    dst_resolved=$(realpath "$dst" 2>/dev/null) || true

    if [[ -z "$dst_resolved" || ! -d "$dst_resolved" ]]; then
        warn "Destination not accessible: $dst (already cleaned up?)"
        return 0
    fi

    # Check if DEST is itself a mount point (--mountpoint requires exact match)
    local actual=""
    actual=$(findmnt -n -o SOURCE --mountpoint "$dst_resolved" 2>/dev/null) || true

    if [[ -z "$actual" ]]; then
        # Not a direct mount point — check if accessible via parent
        local via_parent=""
        via_parent=$(findmnt -n -o SOURCE --target "$dst_resolved" 2>/dev/null) || true

        if [[ -n "$via_parent" ]]; then
            log "$dst accessible via parent mount, not a direct mount point — skipping"
        else
            log "$dst is not mounted — nothing to unmount"
        fi
        return 0
    fi

    # DEST is a direct mount point — unmount it
    log "Unmounting bind mount: $dst"

    if ! sudo /usr/bin/umount "$dst"; then
        warn "Cannot unmount $dst — mount is busy or in use"
        warn "This may be intentional (failed backup investigation) or another process"
        warn "findmnt output:"
        warn "  $(findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$dst_resolved" 2>/dev/null || echo 'n/a')"
        return 0
    fi

    log "Bind mount removed successfully: $dst"
    return 0
}

# -----------------------------------------------------------------------------
# Container operations (Incus)
# -----------------------------------------------------------------------------
# Functions for interacting with Incus containers during backup operations.

# extract_container_path: Extract path from container preserving ownership
# Usage: extract_container_path <container> <source_path> <dest_dir>
#
# Extracts a path relative to container root (/). The source path structure
# is preserved in the destination.
#
# Example:
#   extract_container_path ct-nextcloud etc/nextcloud /srv/staging/nextcloud
#   # Results in: /srv/staging/nextcloud/etc/nextcloud/...
#
# Note: source_path is relative to container root (no leading /)
extract_container_path() {
    local container="$1"
    local src_path="$2"
    local dest_dir="$3"

    if [[ -z "$container" || -z "$src_path" || -z "$dest_dir" ]]; then
        fail 2 "extract_container_path: requires <container> <src_path> <dest_dir>"
    fi

    # Ensure destination exists
    ensure_staging_dir "$dest_dir"

    log "Extracting ${container}:/${src_path} → ${dest_dir}"

    # Stream tar from container, restore with preserved ownership via sudo
    incus exec "$container" -- tar cf - -C / "$src_path" 2>/dev/null \
        | sudo "${BACKUPPC_SBIN_DIR}/tarRestore" -C "$dest_dir" \
        || fail 4 "Failed to extract ${container}:/${src_path}"
}

# extract_container_dir: Extract directory contents from container
# Usage: extract_container_dir <container> <source_dir> <dest_dir>
#
# Extracts the CONTENTS of a directory (not the directory itself) to the
# destination. Useful for service-specific staging paths where you don't
# want the source directory structure replicated.
#
# Example:
#   extract_container_dir ct-mariadb /var/lib/mysql/db/binlogs /export/mariadb/backuppc/server/db/binlogs
#   # Results in: /export/mariadb/backuppc/server/db/binlogs/<contents of binlogs>
#
# Contrast with extract_container_path:
#   extract_container_path ct-mariadb var/lib/mysql/db/binlogs /export/mariadb
#   # Results in: /export/mariadb/var/lib/mysql/db/binlogs/<contents>
#
extract_container_dir() {
    local container="$1"
    local src_dir="$2"
    local dest_dir="$3"

    if [[ -z "$container" || -z "$src_dir" || -z "$dest_dir" ]]; then
        fail 2 "extract_container_dir: requires <container> <src_dir> <dest_dir>"
    fi

    # Normalize source: ensure it has a leading slash for clarity in logs
    [[ "$src_dir" != /* ]] && src_dir="/${src_dir}"

    # Ensure destination exists
    ensure_staging_dir "$dest_dir"

    log "Extracting ${container}:${src_dir}/* → ${dest_dir}/"

    # Stream tar from container using src_dir as base, extracting "."
    # This extracts only the contents, not the directory itself
    incus exec "$container" -- tar cf - -C "$src_dir" . 2>/dev/null \
        | sudo "${BACKUPPC_SBIN_DIR}/tarRestore" -C "$dest_dir" \
        || fail 4 "Failed to extract ${container}:${src_dir}"
}

# copy_container_dir: Copy directory contents from container (backuppc ownership)
# Usage: copy_container_dir <container> <source_dir> <dest_dir>
#
# Similar to extract_container_dir but does NOT preserve ownership.
# Files are owned by the executing user (typically backuppc).
# Use when original ownership is irrelevant (dumps, generated files, metadata).
#
# Contrast with extract_container_dir:
#   extract_container_dir - preserves ownership (requires sudo tarRestore)
#   copy_container_dir    - backuppc ownership (no sudo needed)
#
# Example:
#   copy_container_dir ct-mariadb /tmp/dump /staging/dump
#   # Results in: /staging/dump/<files owned by backuppc>
#
copy_container_dir() {
    local container="$1"
    local src_dir="$2"
    local dest_dir="$3"

    if [[ -z "$container" || -z "$src_dir" || -z "$dest_dir" ]]; then
        fail 2 "copy_container_dir: requires <container> <src_dir> <dest_dir>"
    fi

    # Normalize source: ensure it has a leading slash for clarity in logs
    [[ "$src_dir" != /* ]] && src_dir="/${src_dir}"

    # Ensure destination exists
    ensure_staging_dir "$dest_dir"

    log "Copying ${container}:${src_dir}/* → ${dest_dir}/ (backuppc ownership)"

    # Stream tar from container, extract without sudo
    # --no-same-owner is default for non-root, files owned by executing user
    incus exec "$container" -- tar cf - -C "$src_dir" . 2>/dev/null \
        | tar xf - -C "$dest_dir" \
        || fail 4 "Failed to copy ${container}:${src_dir}"
}

# container_exists: Check if container exists
container_exists() {
    local container="$1"
    incus info "$container" &>/dev/null
}

# container_running: Check if container is running
container_running() {
    local container="$1"
    local status
    status=$(incus info "$container" 2>/dev/null | grep -E '^Status:' | awk '{print $2}')
    [[ "$status" == "RUNNING" ]]
}

# wait_container_ready: Wait for container to be running and network ready
# Usage: wait_container_ready <container> [timeout_seconds]
wait_container_ready() {
    local container="$1"
    local timeout="${2:-30}"
    local elapsed=0

    log "Waiting for container $container to be ready (timeout: ${timeout}s)"

    while ((elapsed < timeout)); do
        if container_running "$container"; then
            # Check if we can exec into it (implies running state)
            if incus exec "$container" -- true &>/dev/null; then
                log "Container $container is ready"
                return 0
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    fail 5 "Timeout waiting for container $container (${timeout}s)"
}

# Capture container package lists into a package list directory
# Usage: capture_container_package_lists <container> <dest_dir>
#
# Note: Currently, only distributions using pacman as package manager are supported
capture_container_package_lists() {
    local container="$1"
    local dest_dir="$2"
    local capture_errors=""
    local rc=0

    if [[ -z "$container" || -z "$dest_dir" ]]; then
        fail 2 "capture_container_package_lists: requires <container> <dest_dir>"
    fi

    # Ensure destination exists
    ensure_staging_dir "$dest_dir"

    log "Capturing package lists for container $container"

    capture_errors=$(mktemp) || fail 5 "Failed to create temp file"
    register_cleanup "rm -f '$capture_errors'"

    incus exec "$container" -- pacman -Qqen \
        > "$dest_dir/pkglist-repo.txt" \
        2> "$capture_errors" \
        || rc=$?
    if [[ $rc -eq 0 ]]; then
        incus exec "$container" -- pacman -Qqem \
            > "$dest_dir/pkglist-aur.txt" \
            || rc=$?
        if [[ $rc -ne 0 ]]; then
            log "No packages outside the official repositories were found (no AUR packages installed)"
        fi
        incus exec "$container" -- pacman -Qe   > "${dest_dir}/pkg-versions.txt"
    else
        warn "Failed to query packages from container '$container' (rc=$rc):"
        while IFS= read -r line; do
            warn "  $line"
        done < "$capture_errors"
        return "$rc"
    fi
}

# require_command: Ensure command is available in container
# Usage: require_container_command <container> <cmd>
require_container_command() {
    local container="$1"
    local cmd="$2"

    if [[ -z "$container" || -z "$cmd" ]]; then
        fail 2 "require_container_command: requires <container> <cmd>"
    fi

    if ! incus exec "$container" -- sh -c "command -v $cmd &>/dev/null"; then
        fail 2 "Required command not found in container $container: $cmd"
    fi
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------

# require_var: Ensure variable is set and non-empty
require_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"

    if [[ -z "$var_value" ]]; then
        fail 2 "Required variable not set: $var_name"
    fi
}

# require_command: Ensure command is available
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        fail 2 "Required command not found: $cmd"
    fi
}

# require_file: Ensure file exists and is readable
require_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        fail 2 "Required file not found: $file"
    fi
    if [[ ! -r "$file" ]]; then
        fail 2 "Required file not readable: $file"
    fi
}

# require_directory: Ensure directory exists
require_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        fail 2 "Required directory not found: $dir"
    fi
}

# -----------------------------------------------------------------------------
# Configuration helpers
# -----------------------------------------------------------------------------

# load_config: Source a configuration file if it exists
# Usage: load_config <config_file> [required]
load_config() {
    local config_file="$1"
    local required="${2:-false}"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || fail 2 "Failed to load config: $config_file"
        debug "Loaded config: $config_file"
    elif [[ "$required" == "true" ]]; then
        fail 2 "Required config file not found: $config_file"
    fi
}

# -----------------------------------------------------------------------------
# Timing helpers
# -----------------------------------------------------------------------------

# timer_start: Start a named timer
# Usage: timer_start <name>
declare -gA _TIMERS=()

timer_start() {
    local name="$1"
    _TIMERS["$name"]=$(date +%s)
}

# timer_elapsed: Get elapsed seconds for a timer
# Usage: elapsed=$(timer_elapsed <name>)
timer_elapsed() {
    local name="$1"
    local start="${_TIMERS[$name]:-$(date +%s)}"
    local now
    now=$(date +%s)
    echo $((now - start))
}

# timer_log: Log elapsed time for a timer
# Usage: timer_log <name> [message]
timer_log() {
    local name="$1"
    local message="${2:-$name completed}"
    local elapsed
    elapsed=$(timer_elapsed "$name")
    log "${message} in ${elapsed}s"
}

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

# is_root: Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# is_backuppc_user: Check if running as backuppc user
is_backuppc_user() {
    [[ "$(id -un)" == "backuppc" ]]
}

# bytes_to_human: Convert bytes to human readable format
bytes_to_human() {
    local bytes="$1"
    if ((bytes >= 1073741824)); then
        echo "$(( bytes / 1073741824 ))G"
    elif ((bytes >= 1048576)); then
        echo "$(( bytes / 1048576 ))M"
    elif ((bytes >= 1024)); then
        echo "$(( bytes / 1024 ))K"
    else
        echo "${bytes}B"
    fi
}

# =============================================================================
# POST-SCRIPT SUPPORT
# =============================================================================
# Functions for BackupPC post-backup scripts (DumpPostUserCmd).
# These handle xferOK status, meta recording, and artifact validation.

# -----------------------------------------------------------------------------
# xferOK status handling
# -----------------------------------------------------------------------------
# BackupPC passes xferOK (1=success, 0=failure) to post-scripts.
# These functions provide standardized parsing and decision logic.

# Global for post-script xferOK status (0=failure, 1=success)
declare -g XFER_OK=0

# Valid BackupPC command types
readonly -a VALID_CMD_TYPES=(
    # Pre-backup commands
    "DumpPreUserCmd"
    "DumpPreShareCmd"
    # Post-backup commands
    "DumpPostUserCmd"
    "DumpPostShareCmd"
    # Restore commands
    "RestorePreUserCmd"
    "RestorePostUserCmd"
    # Archive commands
    "ArchivePreUserCmd"
    "ArchivePostUserCmd"
)

# init_xfer_status: Parse and validate BackupPC's cmdType and xferOK
#
# BackupPC passes cmdType and xferOK to scripts:
#   $Conf{DumpPostUserCmd} = '/path/to/script $cmdType $xferOK';
#
# This function:
#   1. Validates cmdType matches the expected command type
#   2. Validates xferOK is 0 or 1 (for post-commands)
#   3. Sets global XFER_OK accordingly
#
# Usage:
#   init_xfer_status "DumpPostUserCmd" "$1" "$2"   # expected, cmdType, xferOK
#   init_xfer_status "DumpPreUserCmd" "$1"         # expected, cmdType (no xferOK for pre)
#
# Parameters:
#   $1 - Expected command type (e.g., "DumpPostUserCmd")
#   $2 - Actual cmdType from BackupPC
#   $3 - xferOK value (optional for pre-commands, required for post-commands)
#
# Returns:
#   0 - Success, XFER_OK set appropriately
#   1 - Validation failed, XFER_OK=0
#
init_xfer_status() {
    local expected_cmd="${1:-}"
    local actual_cmd="${2:-}"
    local xfer_ok_arg="${3:-}"

    # Strip surrounding quotes (BackupPC may pass quoted values)
    actual_cmd="${actual_cmd#[\"\']}"; actual_cmd="${actual_cmd%[\"\']}"
    xfer_ok_arg="${xfer_ok_arg#[\"\']}"; xfer_ok_arg="${xfer_ok_arg%[\"\']}"

    # Validate expected command type is known
    if [[ -z "$expected_cmd" ]]; then
        error "init_xfer_status: expected command type not specified"
        XFER_OK=0
        return 1
    fi

    local valid_expected=0
    local valid_type
    for valid_type in "${VALID_CMD_TYPES[@]}"; do
        if [[ "$expected_cmd" == "$valid_type" ]]; then
            valid_expected=1
            break
        fi
    done

    if [[ "$valid_expected" -eq 0 ]]; then
        error "init_xfer_status: unknown expected command type '$expected_cmd'"
        error "  Valid types: ${VALID_CMD_TYPES[*]}"
        XFER_OK=0
        return 1
    fi

    # Validate actual cmdType matches expected
    if [[ -z "$actual_cmd" ]]; then
        error "init_xfer_status: cmdType not provided; expected '$expected_cmd'"
        XFER_OK=0
        return 1
    fi

    if [[ "$actual_cmd" != "$expected_cmd" ]]; then
        error "init_xfer_status: cmdType mismatch"
        error "  Expected: $expected_cmd"
        error "  Actual:   $actual_cmd"
        XFER_OK=0
        return 1
    fi

    # Determine if this is a pre or post command
    local is_post_cmd=0
    case "$expected_cmd" in
        *Post*) is_post_cmd=1 ;;
    esac

    # For pre-commands, xferOK is not applicable
    if [[ "$is_post_cmd" -eq 0 ]]; then
        log "BackupPC $actual_cmd: pre-command (xferOK not applicable)"
        XFER_OK=1  # Assume success for pre-commands
        return 0
    fi

    # For post-commands, xferOK is required
    if [[ -z "$xfer_ok_arg" ]]; then
        error "init_xfer_status: xferOK not provided for post-command '$actual_cmd'"
        XFER_OK=0
        return 1
    fi

    case "$xfer_ok_arg" in
        1)
            XFER_OK=1
            log "BackupPC $actual_cmd: xferOK=$XFER_OK (success)"
            ;;
        0)
            XFER_OK=0
            warn "BackupPC $actual_cmd: xferOK=$XFER_OK (failure)"
            ;;
        *)
            error "init_xfer_status: invalid xferOK value '$xfer_ok_arg'; expected 0 or 1"
            XFER_OK=0
            return 1
            ;;
    esac

    return 0
}

# should_preserve_staging: Check if staging should be preserved for investigation
#
# Returns 0 (true) if staging should be preserved:
#   - Script failed (FAILED != 0)
#   - BackupPC transfer failed (XFER_OK != 1)
#
# Returns 1 (false) if staging can be cleaned up (success case)
#
# Usage:
#   if should_preserve_staging; then
#       log "Preserving staging for investigation"
#   else
#       cleanup_staging "$STAGING_DIR"
#   fi
should_preserve_staging() {
    [[ "$FAILED" -ne 0 ]] || [[ "$XFER_OK" -ne 1 ]]
}

# -----------------------------------------------------------------------------
# Meta directory operations
# -----------------------------------------------------------------------------
# Post-scripts record status in a meta/ subdirectory for diagnostics
# and for coordination with monitoring/alerting systems.

# write_meta_xferok: Record BackupPC xferOK and completion timestamp
#
# Creates:
#   <meta_dir>/xferOK      - The xferOK value (0 or 1)
#   <meta_dir>/finished_at - ISO 8601 timestamp
#
# Usage: write_meta_xferok <meta_dir>
write_meta_xferok() {
    local meta_dir="$1"

    if [[ -z "$meta_dir" ]]; then
        warn "write_meta_xferok: meta_dir required"
        return 0
    fi

    mkdir -p -- "$meta_dir" 2>/dev/null || true
    printf '%s\n' "$XFER_OK" > "${meta_dir}/xferOK" 2>/dev/null || true
    date -Is > "${meta_dir}/finished_at" 2>/dev/null || true
}

# write_meta_status: Record final status and optional error message
#
# Creates:
#   <meta_dir>/status - "ok" or "failed"
#   <meta_dir>/error  - Error message (cleared on success)
#
# Usage:
#   write_meta_status <meta_dir> "ok"
#   write_meta_status <meta_dir> "failed" "phase=dump rc=5 msg=timeout"
write_meta_status() {
    local meta_dir="$1"
    local status="$2"
    local err_msg="${3:-}"

    if [[ -z "$meta_dir" || -z "$status" ]]; then
        warn "write_meta_status: meta_dir and status required"
        return 0
    fi

    mkdir -p -- "$meta_dir" 2>/dev/null || true
    printf '%s\n' "$status" > "${meta_dir}/status" 2>/dev/null || true

    if [[ "$status" == "ok" ]]; then
        # Clear stale error on success
        : > "${meta_dir}/error" 2>/dev/null || true
    else
        printf '%s\n' "$err_msg" > "${meta_dir}/error" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Artifact validation helpers
# -----------------------------------------------------------------------------
# Post-scripts validate backup artifacts before declaring success.
# These helpers provide consistent validation with good error messages.

# verify_zstd_file: Verify zstd-compressed file exists and passes integrity test
#
# Checks:
#   1. File exists
#   2. File is non-empty
#   3. zstd -t passes (decompression integrity)
#
# Usage: verify_zstd_file <file> [description]
# Returns: 0 on success, 1 on failure (with error logged)
verify_zstd_file() {
    local file="$1"
    local desc="${2:-$file}"

    if [[ ! -f "$file" ]]; then
        error "Missing artifact: $desc"
        error "  Expected: $file"
        return 1
    fi

    if [[ ! -s "$file" ]]; then
        error "Empty artifact: $desc"
        error "  File: $file"
        return 1
    fi

    if ! zstd -t --quiet "$file" 2>/dev/null; then
        error "Failed zstd integrity test: $desc"
        error "  File: $file"
        return 1
    fi

    log "Verified: $desc ($(stat -c%s "$file" | numfmt --to=iec-i)B)"
    return 0
}

# verify_file_checksum: Verify file against its SHA256 checksum sidecar
#
# Expects <file>.sha256 in sha256sum format: "<hash>  <filename>"
# If checksum file doesn't exist, logs warning but returns success.
#
# Usage: verify_file_checksum <file>
# Returns: 0 on success or missing checksum, 1 on mismatch
verify_file_checksum() {
    local file="$1"
    local checksum_file="${file}.sha256"

    if [[ ! -f "$checksum_file" ]]; then
        debug "No checksum file for: $file"
        return 0
    fi

    local dir name
    dir=$(dirname "$file")
    name=$(basename "$file")

    # Run sha256sum in the file's directory for correct relative path matching
    if ! (cd "$dir" && sha256sum -c "${name}.sha256" --quiet 2>/dev/null); then
        error "Checksum mismatch: $file"
        error "  Checksum file: $checksum_file"
        return 1
    fi

    debug "Checksum verified: $file"
    return 0
}

# verify_directory_exists: Check directory exists and is non-empty
#
# Usage: verify_directory_exists <dir> [description]
# Returns: 0 if exists (may warn if empty), 1 if missing
verify_directory_exists() {
    local dir="$1"
    local desc="${2:-$dir}"

    if [[ ! -d "$dir" ]]; then
        error "Missing directory: $desc"
        error "  Expected: $dir"
        return 1
    fi

    # Check if directory has any contents
    if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        warn "Empty directory: $desc"
    else
        debug "Directory exists: $desc"
    fi

    return 0
}

# verify_file_exists: Check file exists and is readable
#
# Usage: verify_file_exists <file> [description]
# Returns: 0 on success, 1 on failure
verify_file_exists() {
    local file="$1"
    local desc="${2:-$file}"

    if [[ ! -f "$file" ]]; then
        error "Missing file: $desc"
        error "  Expected: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        error "File not readable: $desc"
        error "  File: $file"
        return 1
    fi

    debug "File exists: $desc"
    return 0
}

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------

# Verify we can write to log directory (non-fatal warning)
if [[ ! -d "$BACKUPPC_LOG_DIR" ]]; then
    echo "[WARN] Log directory does not exist: $BACKUPPC_LOG_DIR" >&2
elif [[ ! -w "$BACKUPPC_LOG_DIR" ]]; then
    echo "[WARN] Log directory not writable: $BACKUPPC_LOG_DIR" >&2
fi

# Log library load (only if DEBUG enabled)
debug "common.sh loaded by ${SCRIPT_NAME}"
