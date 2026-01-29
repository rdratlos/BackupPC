#!/bin/bash
# =============================================================================
# Test script for failure handling in common.sh
# sudo -u backuppc tests/test-failure.sh
# =============================================================================
# Run with argument to select test case:
#   ./test-failure.sh success     - Normal successful execution
#   ./test-failure.sh fail        - Explicit fail() call
#   ./test-failure.sh err         - Unexpected command error (ERR trap)
#   ./test-failure.sh cleanup     - Cleanup actions on failure
#   ./test-failure.sh phases      - Phase tracking through execution
#   ./test-failure.sh typo        - Typo in function call (simulates info vs log)
#   ./test-failure.sh func-err    - Error inside a function (tests errtrace)

source "$(dirname "$0")/../lib/backuppc/common.sh"
enable_strict_traps

TEST_CASE="${1:-success}"

# Sample cleanup functions
cleanup_temp() {
    echo "  → cleanup_temp: would remove temp files"
}

cleanup_state() {
    echo "  → cleanup_state: would restore service state"
    echo "    (FAILED=$FAILED, checking if rollback needed)"
}

# Function that contains an error (for func-err test)
function_with_error() {
    PHASE="inside_function"
    log "Inside function_with_error"
    
    # This will fail
    false
    
    # Should not reach here
    log "ERROR: This line should never execute"
}

# Function that contains a typo (for typo test)
function_with_typo() {
    PHASE="inside_function"
    log "Inside function_with_typo"
    
    # Typo: "info" instead of "log" - info is not defined, will fail
    info "This is a typo - should be log not info"
    
    # Should not reach here
    log "ERROR: This line should never execute"
}

echo "=== Failure handling test: $TEST_CASE ==="
echo ""

case "$TEST_CASE" in
    success)
        echo "--- Testing successful execution ---"
        PHASE="initialization"
        log "Starting successful test"

        PHASE="processing"
        log "Processing data..."
        sleep 0.5

        PHASE="finalization"
        log "Finalizing..."

        echo ""
        echo "Failure state check:"
        get_failure_summary
        ;;

    fail)
        echo "--- Testing explicit fail() call ---"
        register_cleanup "cleanup_temp"
        register_cleanup "cleanup_state"

        PHASE="initialization"
        log "Starting fail test"

        PHASE="risky_operation"
        log "About to call fail()..."
        fail 42 "Simulated failure in risky operation"

        # Should not reach here
        echo "ERROR: This line should never execute"
        ;;

    err)
        echo "--- Testing unexpected error (ERR trap) ---"
        register_cleanup "cleanup_temp"
        register_cleanup "cleanup_state"

        PHASE="initialization"
        log "Starting ERR trap test"

        PHASE="command_execution"
        log "About to run a failing command..."

        # This will trigger ERR trap due to set -o errexit
        false

        # Should not reach here
        echo "ERROR: This line should never execute"
        ;;

    cleanup)
        echo "--- Testing cleanup execution order ---"
        register_cleanup "echo '  → Action 1 (registered first, runs last)'"
        register_cleanup "echo '  → Action 2 (registered second)'"
        register_cleanup "echo '  → Action 3 (registered third, runs first)'"

        PHASE="processing"
        log "Registered 3 cleanup actions, now failing..."

        fail 1 "Testing cleanup order"
        ;;

    phases)
        echo "--- Testing phase tracking through execution ---"
        register_cleanup "cleanup_state"

        for phase in init config extract transform load verify; do
            PHASE="$phase"
            log "Executing phase: $phase"
            sleep 0.2

            # Fail during 'transform' phase
            if [[ "$phase" == "transform" ]]; then
                fail 3 "Transform phase failed: data validation error"
            fi
        done
        ;;

    typo)
        echo "--- Testing typo in function name (info vs log) ---"
        echo "This simulates accidentally typing 'info' instead of 'log'"
        echo ""
        register_cleanup "cleanup_temp"
        register_cleanup "cleanup_state"

        PHASE="initialization"
        log "Starting typo test"

        PHASE="calling_function"
        log "Calling function that contains a typo..."
        function_with_typo

        # Should not reach here
        echo "ERROR: This line should never execute"
        ;;

    func-err)
        echo "--- Testing error inside a function (errtrace) ---"
        echo "This verifies ERR trap fires inside functions (set -o errtrace)"
        echo ""
        register_cleanup "cleanup_temp"
        register_cleanup "cleanup_state"

        PHASE="initialization"
        log "Starting function error test"

        PHASE="calling_function"
        log "Calling function that will fail internally..."
        function_with_error

        # Should not reach here
        echo "ERROR: This line should never execute"
        ;;

    *)
        echo "Unknown test case: $TEST_CASE"
        echo ""
        echo "Valid options:"
        echo "  success   - Normal successful execution"
        echo "  fail      - Explicit fail() call"
        echo "  err       - Unexpected command error (ERR trap)"
        echo "  cleanup   - Cleanup actions on failure"
        echo "  phases    - Phase tracking through execution"
        echo "  typo      - Typo in function call (info vs log)"
        echo "  func-err  - Error inside a function (tests errtrace)"
        exit 1
        ;;
esac

echo ""
echo "=== Test complete ==="
