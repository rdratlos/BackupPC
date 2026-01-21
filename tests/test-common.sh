#!/bin/bash
# =============================================================================
# Test script for /usr/local/lib/backuppc/common.sh
# sudo -u backuppc tests/test-common.sh
# =============================================================================

# Can override SCRIPT_NAME before sourcing if desired
# SCRIPT_NAME="my-custom-name"

source "$(dirname "$0")/../lib/backuppc/common.sh"
u=$(id -un)

echo "=== common.sh test suite ==="
echo ""

# Test 1: Script identification
echo "--- Test 1: Script identification ---"
echo "SCRIPT_NAME: $SCRIPT_NAME"
echo "LOG_FILE:    $LOG_FILE"
echo "LOCK_FILE:   $LOCK_FILE"
echo "LOG_TAG:     $LOG_TAG"
echo "USER:        $u"
echo ""

# Test 2: Logging functions
echo "--- Test 2: Logging functions ---"
log "This is an INFO message"
warn "This is a WARN message"
error "This is an ERROR message"
DEBUG=1 debug "This is a DEBUG message (should appear)"
DEBUG=0 debug "This DEBUG message should NOT appear"
echo ""

# Test 3: Validation helpers
echo "--- Test 3: Validation helpers ---"
TEST_VAR="hello"
require_var TEST_VAR && echo "✓ require_var passed for set variable"

require_command bash && echo "✓ require_command passed for 'bash'"

# Test 4: Timer functions
echo ""
echo "--- Test 4: Timer functions ---"
timer_start "test_operation"
sleep 1
timer_log "test_operation" "Test operation"
echo ""

# Test 5: Utility functions
echo "--- Test 5: Utility functions ---"
echo "is_root: $(is_root && echo 'yes' || echo 'no')"
echo "bytes_to_human 1536: $(bytes_to_human 1536)"
echo "bytes_to_human 2097152: $(bytes_to_human 2097152)"
echo "bytes_to_human 3221225472: $(bytes_to_human 3221225472)"
echo ""

# Test 6: Phase tracking
echo "--- Test 6: Phase tracking ---"
echo "Initial PHASE: $PHASE"
PHASE="configuration"
echo "After setting: $PHASE"
PHASE="extraction"
echo "After update: $PHASE"
echo ""

# Test 7: Failure state (without actually failing)
echo "--- Test 7: Failure state inspection ---"
echo "FAILED: $FAILED (should be 0)"
echo "FAIL_RC: $FAIL_RC (should be 0)"
echo "FAIL_MSG: '${FAIL_MSG}' (should be empty)"
echo ""
echo "get_failure_summary (success case):"
get_failure_summary
echo ""

# Test 8: Cleanup registration
echo "--- Test 8: Cleanup registration ---"
register_cleanup "echo '  → Cleanup action 1 executed'"
register_cleanup "echo '  → Cleanup action 2 executed'"
echo "Registered 2 cleanup actions (will execute on exit via on_exit trap)"
echo ""

# Test 9: Lock management
echo "--- Test 9: Lock management ---"
if [[ -d "$BACKUPPC_LOG_DIR" && -w "$BACKUPPC_LOG_DIR" ]]; then
    acquire_lock "test-lock"
    echo "Lock file created: ${BACKUPPC_LOG_DIR}/LOCK.test-lock"
    release_lock
    echo "Lock released"
else
    echo "Skipping lock test (log dir not available)"
fi
echo ""

# Test 10: Enable strict traps (for final exit handling)
echo "--- Test 10: Strict traps ---"
enable_strict_traps
echo "Strict traps enabled - on_exit will run at script end"
echo ""

echo "=== Test suite complete (on_exit trap will now fire) ==="
