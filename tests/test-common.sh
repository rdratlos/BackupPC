#!/bin/bash
# =============================================================================
# Test script for /usr/local/lib/backuppc/common.sh
# sudo -u backuppc tests/test-common.sh
# =============================================================================
#
# Tests core functionality that doesn't require containers or special privileges.
# For container and bind mount tests, see test-integration.sh
#
# Usage:
#   ./test-common.sh          # Run all tests
#   ./test-common.sh quick    # Skip slow tests (timers)

# Can override SCRIPT_NAME before sourcing if desired
# SCRIPT_NAME="my-custom-name"

source "$(dirname "$0")/../lib/backuppc/common.sh"

QUICK_MODE="${1:-}"
TEST_COUNT=0
PASS_COUNT=0

# Test helper functions (output to stderr since log functions use stderr)
test_start() {
    ((TEST_COUNT++)) || true
    echo "--- Test $TEST_COUNT: $1 ---" >&2
}

test_pass() {
    ((PASS_COUNT++)) || true
    echo "✓ $1" >&2
}

test_skip() {
    echo "⊘ SKIPPED: $1" >&2
}

echo "=== common.sh test suite ===" >&2
echo "" >&2

# Test 1: Script identification
test_start "Script identification"
echo "SCRIPT_NAME: $SCRIPT_NAME" >&2
echo "LOG_FILE:    $LOG_FILE" >&2
echo "LOCK_FILE:   $LOCK_FILE" >&2
echo "LOG_TAG:     $LOG_TAG" >&2
[[ -n "$SCRIPT_NAME" ]] && test_pass "SCRIPT_NAME is set"
[[ "$LOG_FILE" == *"LOG."* ]] && test_pass "LOG_FILE follows naming convention"
[[ "$LOCK_FILE" == *"LOCK."* ]] && test_pass "LOCK_FILE follows naming convention"
echo "" >&2

# Test 2: PATH environment setup
test_start "PATH environment setup"
[[ ":$PATH:" == *":/usr/local/sbin:"* ]] && test_pass "PATH contains /usr/local/sbin"
[[ ":$PATH:" == *":/usr/local/bin:"* ]] && test_pass "PATH contains /usr/local/bin"
[[ ":$PATH:" == *":/usr/sbin:"* ]] && test_pass "PATH contains /usr/sbin"
[[ ":$PATH:" == *":/usr/bin:"* ]] && test_pass "PATH contains /usr/bin"
[[ "$(umask)" == "0022" ]] && test_pass "umask is 0022"
echo "" >&2

# Test 3: Logging functions (all go to stderr)
test_start "Logging functions"
log "This is an INFO message"
warn "This is a WARN message"
error "This is an ERROR message"
DEBUG=1 debug "This is a DEBUG message (should appear)"
DEBUG=0 debug "This DEBUG message should NOT appear"
log_indent "This is an indented INFO message"
log_indent "Custom indent message" "    "
log_indent "Indented warning" "  " WARN
test_pass "Logging functions executed without error"
test_pass "log_indent executed without error"
echo "" >&2

# Test 4: Validation helpers
test_start "Validation helpers"
TEST_VAR="hello"
require_var TEST_VAR && test_pass "require_var passed for set variable"
require_command bash && test_pass "require_command passed for 'bash'"
require_command ls && test_pass "require_command passed for 'ls'"

# Test require_file with a known file
if [[ -f /etc/passwd ]]; then
    require_file /etc/passwd && test_pass "require_file passed for /etc/passwd"
fi

# Test require_directory
require_directory /tmp && test_pass "require_directory passed for /tmp"
echo "" >&2

# Test 5: Timer functions
test_start "Timer functions"
if [[ "$QUICK_MODE" == "quick" ]]; then
    test_skip "Timer test (quick mode)"
else
    timer_start "test_operation"
    sleep 1
    elapsed=$(timer_elapsed "test_operation")
    [[ "$elapsed" -ge 1 ]] && test_pass "timer_elapsed returned $elapsed seconds"
    timer_log "test_operation" "Test operation"
    
    # Test timer_elapsed with non-existent timer (should return 0, using current time as default)
    elapsed_nonexistent=$(timer_elapsed "nonexistent_timer")
    [[ "$elapsed_nonexistent" -eq 0 ]] && test_pass "timer_elapsed returns 0 for non-existent timer"
fi
echo "" >&2

# Test 6: Utility functions
test_start "Utility functions"
echo "is_root: $(is_root && echo 'yes' || echo 'no')" >&2
echo "is_backuppc_user: $(is_backuppc_user && echo 'yes' || echo 'no')" >&2

result=$(bytes_to_human 512)
[[ "$result" == "512B" ]] && test_pass "bytes_to_human 512 = $result"

result=$(bytes_to_human 1536)
[[ "$result" == "1K" ]] && test_pass "bytes_to_human 1536 = $result"

result=$(bytes_to_human 2097152)
[[ "$result" == "2M" ]] && test_pass "bytes_to_human 2097152 = $result"

result=$(bytes_to_human 3221225472)
[[ "$result" == "3G" ]] && test_pass "bytes_to_human 3221225472 = $result"
echo "" >&2

# Test 7: Phase tracking
test_start "Phase tracking"
echo "Initial PHASE: $PHASE" >&2
[[ "$PHASE" == "init" ]] && test_pass "Initial PHASE is 'init'"

PHASE="configuration"
[[ "$PHASE" == "configuration" ]] && test_pass "PHASE updated to 'configuration'"

PHASE="extraction"
[[ "$PHASE" == "extraction" ]] && test_pass "PHASE updated to 'extraction'"
echo "" >&2

# Test 8: Failure state (without actually failing)
test_start "Failure state inspection"
echo "FAILED: $FAILED (should be 0)" >&2
echo "FAIL_RC: $FAIL_RC (should be 0)" >&2
echo "FAIL_MSG: '${FAIL_MSG}' (should be empty)" >&2
[[ "$FAILED" -eq 0 ]] && test_pass "FAILED is 0"
[[ "$FAIL_RC" -eq 0 ]] && test_pass "FAIL_RC is 0"
[[ -z "$FAIL_MSG" ]] && test_pass "FAIL_MSG is empty"

echo "" >&2
echo "get_failure_summary (success case):" >&2
summary=$(get_failure_summary)
echo "$summary" >&2
[[ "$summary" == "status=success" ]] && test_pass "get_failure_summary returns success"
echo "" >&2

# Test 9: Cleanup registration
test_start "Cleanup registration"
initial_count=${#_CLEANUP_ACTIONS[@]}
register_cleanup "echo '  → Test cleanup action 1' >&2"
register_cleanup "echo '  → Test cleanup action 2' >&2"
new_count=${#_CLEANUP_ACTIONS[@]}
[[ $((new_count - initial_count)) -eq 2 ]] && test_pass "Registered 2 cleanup actions"
echo "Total cleanup actions registered: $new_count" >&2
echo "" >&2

# Test 10: Lock management
test_start "Lock management"
if [[ -d "$BACKUPPC_LOG_DIR" && -w "$BACKUPPC_LOG_DIR" ]]; then
    acquire_lock "test-lock-$$"
    test_pass "Lock acquired"
    # Note: release_lock is registered as cleanup action, will run on exit
    # Don't call release_lock here - it confuses FD handling
    rm -f "${BACKUPPC_LOG_DIR}/LOCK.test-lock-$$" 2>/dev/null || true
else
    test_skip "Lock test (log dir not available: $BACKUPPC_LOG_DIR)"
fi
echo "" >&2

# Test 11: Staging directory functions
test_start "Staging directory functions"
TEST_STAGING="/tmp/test-staging-$$"
ensure_staging_dir "$TEST_STAGING"
[[ -d "$TEST_STAGING" ]] && test_pass "ensure_staging_dir created directory"

ensure_staging_dir "$TEST_STAGING/subdir" 0750
[[ -d "$TEST_STAGING/subdir" ]] && test_pass "ensure_staging_dir created subdirectory"

# Cleanup test staging
rm -rf "$TEST_STAGING"
test_pass "Test staging cleaned up"
echo "" >&2

# Test 12: Configuration helpers
test_start "Configuration helpers"
TEST_CONFIG="/tmp/test-config-$$.conf"
echo 'TEST_CONFIG_VAR="loaded"' > "$TEST_CONFIG"
load_config "$TEST_CONFIG"
[[ "${TEST_CONFIG_VAR:-}" == "loaded" ]] && test_pass "load_config sourced config file"
rm -f "$TEST_CONFIG"

# Test optional config (should not fail)
load_config "/nonexistent/config.conf" false && test_pass "load_config handles missing optional config"
echo "" >&2

# Test 13: Bind mount functions (signature validation only)
test_start "Bind mount functions (signature validation)"
# We can't test actual mounting without root, but we can verify functions exist
if declare -f ensure_bind_mount > /dev/null; then
    test_pass "ensure_bind_mount function exists"
else
    echo "✗ ensure_bind_mount function not found" >&2
fi

if declare -f remove_bind_mount > /dev/null; then
    test_pass "remove_bind_mount function exists"
else
    echo "✗ remove_bind_mount function not found" >&2
fi
echo "" >&2

# Test 14: Container functions (existence check only)
test_start "Container functions (signature validation)"
for func in container_exists container_running require_running_container \
            wait_container_ready extract_container_path extract_container_dir \
            copy_container_dir capture_container_package_lists require_container_command; do
    if declare -f "$func" > /dev/null; then
        test_pass "$func function exists"
    else
        echo "✗ $func function not found" >&2
    fi
done
echo "" >&2

# Test 15: Post-script xferOK functions
test_start "Post-script xferOK functions"

# Test init_xfer_status with valid post-command types
init_xfer_status "DumpPostUserCmd" "DumpPostUserCmd" "1"
[[ "$XFER_OK" -eq 1 ]] && test_pass "init_xfer_status accepts DumpPostUserCmd with xferOK=1"

init_xfer_status "DumpPostUserCmd" "DumpPostUserCmd" "0"
[[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status accepts DumpPostUserCmd with xferOK=0"

init_xfer_status "RestorePostUserCmd" "RestorePostUserCmd" "1"
[[ "$XFER_OK" -eq 1 ]] && test_pass "init_xfer_status accepts RestorePostUserCmd"

init_xfer_status "ArchivePostUserCmd" "ArchivePostUserCmd" "1"
[[ "$XFER_OK" -eq 1 ]] && test_pass "init_xfer_status accepts ArchivePostUserCmd"

# Test pre-command types (no xferOK required)
init_xfer_status "DumpPreUserCmd" "DumpPreUserCmd"
[[ "$XFER_OK" -eq 1 ]] && test_pass "init_xfer_status accepts DumpPreUserCmd (no xferOK)"

init_xfer_status "DumpPreShareCmd" "DumpPreShareCmd"
[[ "$XFER_OK" -eq 1 ]] && test_pass "init_xfer_status accepts DumpPreShareCmd (no xferOK)"

# Test cmdType mismatch rejection
if ! init_xfer_status "DumpPostUserCmd" "DumpPreUserCmd" "1" 2>/dev/null; then
    [[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status rejects cmdType mismatch"
fi

# Test rejection of invalid expected command
if ! init_xfer_status "InvalidCommand" "InvalidCommand" "1" 2>/dev/null; then
    [[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status rejects invalid expected cmdType"
fi

# Test rejection of missing actual cmdType
if ! init_xfer_status "DumpPostUserCmd" "" "1" 2>/dev/null; then
    [[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status rejects empty actual cmdType"
fi

# Test rejection of missing xferOK for post-command
if ! init_xfer_status "DumpPostUserCmd" "DumpPostUserCmd" "" 2>/dev/null; then
    [[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status rejects missing xferOK for post-cmd"
fi

# Test rejection of invalid xferOK value
if ! init_xfer_status "DumpPostUserCmd" "DumpPostUserCmd" "2" 2>/dev/null; then
    [[ "$XFER_OK" -eq 0 ]] && test_pass "init_xfer_status rejects invalid xferOK value"
fi

# Test should_preserve_staging
XFER_OK=1
FAILED=0
if ! should_preserve_staging; then
    test_pass "should_preserve_staging returns false on success"
fi

XFER_OK=0
FAILED=0
if should_preserve_staging; then
    test_pass "should_preserve_staging returns true on xfer failure"
fi

XFER_OK=1
FAILED=1
if should_preserve_staging; then
    test_pass "should_preserve_staging returns true on script failure"
fi

# Reset state
XFER_OK=0
FAILED=0
echo "" >&2

# Test 16: Meta directory functions
test_start "Meta directory functions"
TEST_META="/tmp/test-meta-$$"
mkdir -p "$TEST_META"

write_meta_xferok "$TEST_META"
[[ -f "$TEST_META/xferOK" ]] && test_pass "write_meta_xferok creates xferOK file"
[[ -f "$TEST_META/finished_at" ]] && test_pass "write_meta_xferok creates finished_at file"

write_meta_status "$TEST_META" "ok"
[[ "$(cat "$TEST_META/status")" == "ok" ]] && test_pass "write_meta_status writes 'ok'"

write_meta_status "$TEST_META" "failed" "test error message"
[[ "$(cat "$TEST_META/status")" == "failed" ]] && test_pass "write_meta_status writes 'failed'"
[[ "$(cat "$TEST_META/error")" == "test error message" ]] && test_pass "write_meta_status writes error message"

rm -rf "$TEST_META"
echo "" >&2

# Test 17: File/directory verification functions
test_start "Artifact verification functions"

# Test verify_file_exists
TEST_FILE="/tmp/test-file-$$"
echo "test content" > "$TEST_FILE"
if verify_file_exists "$TEST_FILE" "test file"; then
    test_pass "verify_file_exists succeeds for existing file"
fi

if ! verify_file_exists "/nonexistent/file" "missing file" 2>/dev/null; then
    test_pass "verify_file_exists fails for missing file"
fi
rm -f "$TEST_FILE"

# Test verify_directory_exists
TEST_DIR="/tmp/test-dir-$$"
mkdir -p "$TEST_DIR"
if verify_directory_exists "$TEST_DIR" "test directory"; then
    test_pass "verify_directory_exists succeeds for existing directory"
fi

if ! verify_directory_exists "/nonexistent/dir" "missing dir" 2>/dev/null; then
    test_pass "verify_directory_exists fails for missing directory"
fi

# Test verify_directory_exists with empty directory (should warn but succeed)
if verify_directory_exists "$TEST_DIR" "empty directory" 2>/dev/null; then
    test_pass "verify_directory_exists succeeds for empty directory (with warning)"
fi
rmdir "$TEST_DIR"

# Test verify_file_checksum - no checksum file (should succeed)
TEST_FILE="/tmp/test-checksum-$$"
echo "test" > "$TEST_FILE"
if verify_file_checksum "$TEST_FILE"; then
    test_pass "verify_file_checksum succeeds when no checksum file exists"
fi

# Test verify_file_checksum - matching checksum
(cd /tmp && sha256sum "test-checksum-$$" > "test-checksum-$$.sha256")
if verify_file_checksum "$TEST_FILE"; then
    test_pass "verify_file_checksum succeeds with matching checksum"
fi

# Test verify_file_checksum - mismatching checksum
echo "0000000000000000000000000000000000000000000000000000000000000000  test-checksum-$$" > "/tmp/test-checksum-$$.sha256"
if ! verify_file_checksum "$TEST_FILE" 2>/dev/null; then
    test_pass "verify_file_checksum fails with mismatching checksum"
fi
rm -f "$TEST_FILE" "/tmp/test-checksum-$$.sha256"

# Test verify_zstd_file (only if zstd is available)
if command -v zstd &>/dev/null; then
    TEST_ZSTD="/tmp/test-zstd-$$"
    
    # Create a valid zstd file
    echo "test content for zstd" | zstd -q > "${TEST_ZSTD}.zst"
    if verify_zstd_file "${TEST_ZSTD}.zst" "test zstd file"; then
        test_pass "verify_zstd_file succeeds for valid zstd file"
    fi
    
    # Test with non-existent file
    if ! verify_zstd_file "/nonexistent/file.zst" "missing zstd" 2>/dev/null; then
        test_pass "verify_zstd_file fails for missing file"
    fi
    
    # Test with empty file
    : > "${TEST_ZSTD}.empty.zst"
    if ! verify_zstd_file "${TEST_ZSTD}.empty.zst" "empty zstd" 2>/dev/null; then
        test_pass "verify_zstd_file fails for empty file"
    fi
    
    # Test with corrupted/invalid zstd file
    echo "not a zstd file" > "${TEST_ZSTD}.invalid.zst"
    if ! verify_zstd_file "${TEST_ZSTD}.invalid.zst" "invalid zstd" 2>/dev/null; then
        test_pass "verify_zstd_file fails for invalid zstd file"
    fi
    
    rm -f "${TEST_ZSTD}.zst" "${TEST_ZSTD}.empty.zst" "${TEST_ZSTD}.invalid.zst"
else
    test_skip "verify_zstd_file tests (zstd not installed)"
    # Still verify function exists
    if declare -f verify_zstd_file > /dev/null; then
        test_pass "verify_zstd_file function exists"
    fi
fi
echo "" >&2

# Test 18: Enable strict traps (for final exit handling)
test_start "Strict traps"
enable_strict_traps
test_pass "Strict traps enabled - on_exit will run at script end"
echo "" >&2

# Summary
echo "========================================" >&2
echo "Test Results: $PASS_COUNT passed" >&2
echo "========================================" >&2
echo "" >&2
echo "=== Test suite complete (on_exit trap will now fire) ===" >&2
