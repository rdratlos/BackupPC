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
#   - incus (for container operations)
#   - sudo access to tarCreate/tarRestore/backuppc-staging-cleanup
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

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly BACKUPPC_LOG_DIR="/var/log/backuppc"
readonly BACKUPPC_LIB_DIR="/usr/local/lib/backuppc"
readonly BACKUPPC_SBIN_DIR="/usr/local/sbin"

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

    # Console output
    case "$level" in
        ERROR|WARN) echo "$formatted" >&2 ;;
        *)          echo "$formatted" ;;
    esac
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
# on_err: ERR trap handler - captures unexpected errors
# Triggered by set -o errexit when a command fails.
#
# Note: To enable, scripts must call: trap 'on_err' ERR
#       Or use: enable_strict_traps

on_err() {
    local rc=$?

    # Capture failure details
    if [[ "$FAILED" -eq 0 ]]; then
        FAILED=1
        FAIL_RC="$rc"
        FAIL_PHASE="$PHASE"
        FAIL_LINE="${BASH_LINENO[0]:-unknown}"
        FAIL_CMD="${BASH_COMMAND:-unknown}"
        FAIL_MSG="command failed: ${FAIL_CMD}"
        error "Unexpected error: phase=${FAIL_PHASE} rc=${rc} line=${FAIL_LINE} cmd=${FAIL_CMD}"
    else
        # Additional error during cleanup/exit - log but don't override original
        warn "Additional error: phase=${PHASE} rc=${rc} line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}"
    fi

    return "$rc"
}

# on_exit: EXIT trap handler - runs cleanup and reports final status
# This is the main exit handler that:
#   1. Runs registered cleanup actions
#   2. Reports success/failure with context
#   3. Exits with appropriate code
#
# Note: Automatically installed by enable_strict_traps or can be
#       manually set with: trap 'on_exit' EXIT

on_exit() {
    local rc=$?

    # If we're exiting due to a failure, use the captured code
    # Otherwise use the actual exit code
    local final_rc="${FAIL_RC:-$rc}"
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
            ((cleanup_errors++)) || true
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
# Container operations (Incus)
# -----------------------------------------------------------------------------
# Functions for interacting with Incus containers during backup operations.

# extract_container_path: Extract path from container preserving ownership
# Usage: extract_container_path <container> <source_path> <dest_dir>
#
# Example:
#   extract_container_path ct-nextcloud etc/nextcloud /srv/staging/nextcloud/etc
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
        ((elapsed++))
    done

    fail 5 "Timeout waiting for container $container (${timeout}s)"
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
