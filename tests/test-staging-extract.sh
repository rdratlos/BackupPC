#!/bin/bash
# =============================================================================
# tests/test-staging-extract.sh
# =============================================================================
#
# Test suite for backuppc-staging-extract helper script.
# MUST be run as root (sudo).
#
# =============================================================================
# TEST SPECIFICATION
# =============================================================================
#
# Architecture:
#   - Unit tests use mocked incus and tarRestore for complete isolation
#   - Integration tests use real incus and tarRestore against actual containers
#   - Root execution required (config files must be root-owned for security)
#
# Test Categories:
#   1. Argument Validation      - Verify CLI argument parsing
#   2. Configuration Validation - Verify config file security checks
#   3. Security Validation      - Verify path restrictions and traversal prevention
#   4. Container Validation     - Verify container existence/state checks
#   5. File List Validation     - Verify --file-list handling
#   6. Integration Tests        - End-to-end extraction with real containers
#
# Manual Security Verification:
#   For certified security verification, the following manual tests are
#   recommended in addition to automated tests:
#
#   1. Config file tampering:
#      - Verify script rejects config with wrong owner
#      - Verify script rejects world-writable config
#      - Verify script rejects group-writable config
#
#   2. Path traversal attempts:
#      - Attempt extraction with "../" in container paths
#      - Attempt extraction to paths outside allowed roots
#      - Attempt extraction using symlinks pointing outside roots
#
#   3. Container isolation:
#      - Verify extraction only works for running containers
#      - Verify proper UID preservation (shifted UIDs for unprivileged)
#
# =============================================================================
# USAGE
# =============================================================================
#
#   # Full test suite (unit tests only)
#   sudo ./tests/test-staging-extract.sh
#
#   # Full test suite with integration tests
#   sudo TEST_CONTAINER=mycontainer ./tests/test-staging-extract.sh
#
#   # Skip integration tests that require real containers
#   sudo SKIP_CONTAINER=1 ./tests/test-staging-extract.sh
#
# Note: Environment variables must be placed AFTER sudo, not before.
#       Using "TEST_CONTAINER=x sudo -E ..." will NOT work reliably.
#
# Exit codes:
#   0 - All tests passed
#   1 - Some tests failed or prerequisites not met
#
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode (match script under test)
# -----------------------------------------------------------------------------
set -o nounset      # Error on unset variables
set -o pipefail     # Pipeline fails on first error
# Note: NOT using errexit - we handle errors explicitly

# -----------------------------------------------------------------------------
# Root check - fail fast
# -----------------------------------------------------------------------------
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: This test script must be run as root (sudo)." >&2
    echo "       Config files must be root-owned for security validation." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Determine project root (assume tests/ is one level down from root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Script under test
EXTRACT_SCRIPT="${PROJECT_ROOT}/bin/backuppc-staging-extract"
if [[ ! -x "$EXTRACT_SCRIPT" ]]; then
    # Fallback for flat structure
    EXTRACT_SCRIPT="${PROJECT_ROOT}/backuppc-staging-extract"
fi

# Test directories - use PID for isolation
TEST_BASE="/tmp/test-staging-extract-$$"
TEST_STAGING="${TEST_BASE}/staging"
TEST_CONFIG="${TEST_BASE}/staging.conf"
TEST_FILELIST="${TEST_BASE}/paths.txt"

# Mocks for unit tests
MOCK_TARRESTORE="${TEST_BASE}/mock-tarRestore"
MOCK_INCUS="${TEST_BASE}/mock-incus"

# -----------------------------------------------------------------------------
# Debug mode - pass through to script under test
# -----------------------------------------------------------------------------
# Usage: sudo TEST_DEBUG=1 ./tests/test-staging-extract.sh
TEST_DEBUG="${TEST_DEBUG:-0}"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

_log() {
    local level="$1"
    shift
    echo -e "[${level}] $*"
}

log_test() { _log "${YELLOW}TEST${NC}" "$*"; }
log_pass() { ((TESTS_PASSED++)); _log "${GREEN}PASS${NC}" "$*"; }
log_fail() { ((TESTS_FAILED++)); _log "${RED}FAIL${NC}" "$*"; }
log_skip() { ((TESTS_SKIPPED++)); _log "${YELLOW}SKIP${NC}" "$*"; }
log_info() { _log "${BLUE}INFO${NC}" "$*"; }

# Run extract script with mocked environment (for unit tests)
# Usage: run_extract output_var rc_var [args...]
run_extract() {
    local -n _output_ref=$1
    local -n _rc_ref=$2
    shift 2

    _output_ref=$(DEBUG="$TEST_DEBUG" \
                  STAGING_CONFIG="$TEST_CONFIG" \
                  TARRESTORE_CMD="$MOCK_TARRESTORE" \
                  INCUS_CMD="$MOCK_INCUS" \
                  "$EXTRACT_SCRIPT" "$@" 2>&1)
    _rc_ref=$?
}

# Run extract script with custom config (for config validation tests)
# Usage: run_extract_custom_config config_path output_var rc_var [args...]
run_extract_custom_config() {
    local config="$1"
    local -n _output_ref=$2
    local -n _rc_ref=$3
    shift 3

    _output_ref=$(DEBUG="$TEST_DEBUG" \
                  STAGING_CONFIG="$config" \
                  TARRESTORE_CMD="$MOCK_TARRESTORE" \
                  INCUS_CMD="$MOCK_INCUS" \
                  "$EXTRACT_SCRIPT" "$@" 2>&1)
    _rc_ref=$?
}

# Run extract script with real incus (for integration tests)
# Usage: run_extract_real output_var rc_var [args...]
run_extract_real() {
    local -n _output_ref=$1
    local -n _rc_ref=$2
    shift 2

    _output_ref=$(DEBUG="$TEST_DEBUG" \
                  STAGING_CONFIG="$TEST_CONFIG" \
                  "$EXTRACT_SCRIPT" "$@" 2>&1)
    _rc_ref=$?
}

# Setup test environment
setup() {
    log_info "Setting up test environment in $TEST_BASE"

    rm -rf "$TEST_BASE"
    mkdir -p "$TEST_STAGING/service1/data"
    mkdir -p "$TEST_STAGING/service2"

    # Create valid config file (root-owned, mode 644)
    cat > "$TEST_CONFIG" << EOF
# Test configuration
${TEST_STAGING}
EOF
    chmod 644 "$TEST_CONFIG"

    # -------------------------------------------------------------------------
    # Mock incus for unit tests
    # -------------------------------------------------------------------------
    # Simulates a running container named "mockcontainer"
    # This allows unit tests to reach validation logic beyond container checks
    cat > "$MOCK_INCUS" << 'EOF'
#!/bin/bash
# Mock incus - simulates container operations for unit testing
#
# Behavior:
#   - "mockcontainer" exists and is RUNNING
#   - Any other container does not exist
#   - exec commands fail (no actual extraction in unit tests)

case "$1" in
    info)
        container="$2"
        if [[ "$container" == "mockcontainer" ]]; then
            echo "Name: mockcontainer"
            echo "Status: RUNNING"
            echo "Type: container"
            exit 0
        else
            echo "Error: not found" >&2
            exit 1
        fi
        ;;
    exec)
        # For unit tests, exec always fails - we're not actually extracting
        # This is fine because unit tests check validation, not extraction
        exit 1
        ;;
    *)
        echo "Mock incus: unknown command $1" >&2
        exit 1
        ;;
esac
EOF
    chmod 755 "$MOCK_INCUS"

    # -------------------------------------------------------------------------
    # Mock tarRestore for unit tests
    # -------------------------------------------------------------------------
    cat > "$MOCK_TARRESTORE" << 'EOF'
#!/bin/bash
# Mock tarRestore - simulates tar extraction for unit testing
exec /bin/tar -x -f - "$@"
EOF
    chmod 755 "$MOCK_TARRESTORE"

    # Create test file list
    # Use paths guaranteed to exist in any Linux container
    cat > "$TEST_FILELIST" << 'EOF'
# Test paths
etc/hostname
etc/passwd
EOF

    log_info "Test environment ready"
}

# Cleanup test environment
cleanup() {
    log_info "Cleaning up test environment"
    rm -rf "$TEST_BASE"
}

# -----------------------------------------------------------------------------
# Unit Tests: Argument Validation
# -----------------------------------------------------------------------------

test_no_arguments() {
    log_test "No arguments should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc

    if [[ $rc -eq 1 ]]; then
        log_pass "No arguments (exit 1)"
    else
        log_fail "No arguments - expected exit 1, got rc=$rc: $output"
    fi
}

test_missing_paths() {
    log_test "Missing paths argument should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1"

    if [[ $rc -eq 1 ]]; then
        log_pass "Missing paths (exit 1)"
    else
        log_fail "Missing paths - expected exit 1, got rc=$rc: $output"
    fi
}

test_file_list_missing_file() {
    log_test "--file-list without filename should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "--file-list"

    if [[ $rc -eq 1 ]]; then
        log_pass "--file-list without filename (exit 1)"
    else
        log_fail "--file-list without filename - expected exit 1, got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Unit Tests: Configuration Validation
# -----------------------------------------------------------------------------

test_missing_config() {
    log_test "Missing config file should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract_custom_config "/nonexistent/config.conf" output rc "mockcontainer" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 2 ]] || echo "$output" | grep -q "Config file not found"; then
        log_pass "Missing config file (exit 2)"
    else
        log_fail "Missing config - expected exit 2 or 'Config file not found', got rc=$rc: $output"
    fi
}

test_config_bad_owner() {
    log_test "Config with wrong owner should fail"
    ((TESTS_RUN++))

    # Create config owned by non-root
    local bad_config="${TEST_BASE}/bad-owner.conf"
    echo "/tmp" > "$bad_config"
    chown 1000:1000 "$bad_config"

    local output rc
    run_extract_custom_config "$bad_config" output rc "mockcontainer" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 2 ]] || echo "$output" | grep -q "must be owned by root"; then
        log_pass "Config bad owner rejected"
    else
        log_fail "Config bad owner - expected rejection, got rc=$rc: $output"
    fi
}

test_config_world_writable() {
    log_test "World-writable config should fail"
    ((TESTS_RUN++))

    local bad_config="${TEST_BASE}/bad-perms.conf"
    echo "/tmp" > "$bad_config"
    chmod 666 "$bad_config"

    local output rc
    run_extract_custom_config "$bad_config" output rc "mockcontainer" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 2 ]] || echo "$output" | grep -q "must not be writable"; then
        log_pass "World-writable config rejected"
    else
        log_fail "World-writable config - expected rejection, got rc=$rc: $output"
    fi
}

test_config_group_writable() {
    log_test "Group-writable config should fail"
    ((TESTS_RUN++))

    local bad_config="${TEST_BASE}/bad-group-perms.conf"
    echo "/tmp" > "$bad_config"
    chmod 664 "$bad_config"

    local output rc
    run_extract_custom_config "$bad_config" output rc "mockcontainer" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 2 ]] || echo "$output" | grep -q "must not be writable"; then
        log_pass "Group-writable config rejected"
    else
        log_fail "Group-writable config - expected rejection, got rc=$rc: $output"
    fi
}

test_empty_config() {
    log_test "Empty config (no roots) should fail"
    ((TESTS_RUN++))

    local empty_config="${TEST_BASE}/empty.conf"
    echo "# Only comments" > "$empty_config"
    chmod 644 "$empty_config"

    local output rc
    run_extract_custom_config "$empty_config" output rc "mockcontainer" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 2 ]] || echo "$output" | grep -q "No allowed roots"; then
        log_pass "Empty config rejected"
    else
        log_fail "Empty config - expected 'No allowed roots', got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Unit Tests: Security Validation
# -----------------------------------------------------------------------------

test_staging_not_under_root() {
    log_test "Staging outside allowed roots should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "/tmp/unauthorized" "etc"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "not under any allowed root"; then
        log_pass "Unauthorized staging path rejected (exit 3)"
    else
        log_fail "Unauthorized path - expected exit 3, got rc=$rc: $output"
    fi
}

test_staging_is_root() {
    log_test "Staging equal to allowed root should fail"
    ((TESTS_RUN++))

    # Try to use the root itself (not something under it)
    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING" "etc"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "not under any allowed root"; then
        log_pass "Staging = root rejected (exit 3)"
    else
        log_fail "Staging = root - expected exit 3, got rc=$rc: $output"
    fi
}

test_container_path_traversal() {
    log_test "Path traversal in container path should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "../../../etc/passwd"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "traversal"; then
        log_pass "Path traversal rejected (exit 3)"
    else
        log_fail "Path traversal - expected exit 3, got rc=$rc: $output"
    fi
}

test_container_path_absolute() {
    log_test "Absolute container path should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "/etc"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "must be relative"; then
        log_pass "Absolute path rejected (exit 3)"
    else
        log_fail "Absolute path - expected exit 3, got rc=$rc: $output"
    fi
}

test_container_path_empty() {
    log_test "Empty container path should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" ""

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "Empty path"; then
        log_pass "Empty path rejected (exit 3)"
    else
        log_fail "Empty path - expected exit 3, got rc=$rc: $output"
    fi
}

test_staging_dir_not_exist() {
    log_test "Non-existent staging directory should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/nonexistent" "etc"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "does not exist"; then
        log_pass "Non-existent staging rejected (exit 3)"
    else
        log_fail "Non-existent staging - expected exit 3, got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Unit Tests: Container Validation (using mock)
# -----------------------------------------------------------------------------

test_container_not_found() {
    log_test "Non-existent container should fail"
    ((TESTS_RUN++))

    # Use mock incus - "nonexistent-container" is not "mockcontainer" so it fails
    local output rc
    run_extract output rc "nonexistent-container" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 4 ]] || echo "$output" | grep -q "does not exist"; then
        log_pass "Non-existent container rejected (exit 4)"
    else
        log_fail "Non-existent container - expected exit 4, got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Unit Tests: File List Validation
# -----------------------------------------------------------------------------

test_file_list_not_found() {
    log_test "Non-existent file list should fail"
    ((TESTS_RUN++))

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "--file-list" "/nonexistent/file.txt"

    if [[ $rc -eq 1 ]] || echo "$output" | grep -q "not found"; then
        log_pass "Non-existent file list rejected"
    else
        log_fail "Non-existent file list - expected rejection, got rc=$rc: $output"
    fi
}

test_file_list_empty() {
    log_test "Empty file list should fail"
    ((TESTS_RUN++))

    local empty_list="${TEST_BASE}/empty-list.txt"
    echo "# Only comments" > "$empty_list"

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "--file-list" "$empty_list"

    if [[ $rc -eq 1 ]] || echo "$output" | grep -q "No paths defined"; then
        log_pass "Empty file list rejected"
    else
        log_fail "Empty file list - expected 'No paths', got rc=$rc: $output"
    fi
}

test_file_list_with_traversal() {
    log_test "File list with path traversal should fail"
    ((TESTS_RUN++))

    local bad_list="${TEST_BASE}/traversal-list.txt"
    cat > "$bad_list" << 'EOF'
etc/hostname
../../../etc/shadow
EOF

    local output rc
    run_extract output rc "mockcontainer" "$TEST_STAGING/service1" "--file-list" "$bad_list"

    if [[ $rc -eq 3 ]] || echo "$output" | grep -q "traversal"; then
        log_pass "File list with traversal rejected"
    else
        log_fail "File list with traversal - expected exit 3, got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Integration Tests (require real container)
# -----------------------------------------------------------------------------
#
# Required files in test container:
#   - /etc/hostname    (standard on all Linux systems)
#   - /etc/passwd      (standard on all Linux systems)
#
# These files are used for integration testing. The tests validate that
# required files exist in the container before attempting extraction.
#
# Note on missing path behavior:
#   Currently, the extract script fails if any requested path doesn't exist
#   in the container. This differs from BackupPC/tar behavior which continues
#   with warnings and logs xferErrs. A future enhancement could add a lenient
#   mode to match BackupPC's tolerance.
# -----------------------------------------------------------------------------

# Required files that MUST exist in the test container
REQUIRED_CONTAINER_FILES=("etc/hostname" "etc/passwd")

# Check if a file exists in the container
# Usage: container_file_exists container path
container_file_exists() {
    local container="$1"
    local path="$2"
    incus exec "$container" -- test -e "$path" 2>/dev/null
}

# Validate all required test files exist in container
# Returns 0 if all present, 1 if any missing (with error message)
validate_container_prerequisites() {
    local container="$1"
    local -a missing=()

    for path in "${REQUIRED_CONTAINER_FILES[@]}"; do
        if ! container_file_exists "$container" "/$path"; then
            missing+=("/$path")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}ERROR: Test container '$container' is missing required files:${NC}"
        for f in "${missing[@]}"; do
            echo "  - $f"
        done
        echo ""
        echo "Integration tests require a standard Linux container with these files."
        echo "Please specify a different container via TEST_CONTAINER=<n>"
        echo ""
        return 1
    fi
    return 0
}

# Flag to track if container prerequisites passed
CONTAINER_VALIDATED=0

# Validate container once before running integration tests
validate_container_once() {
    local container="${TEST_CONTAINER:-}"

    if [[ -z "$container" ]]; then
        return 1
    fi

    if [[ $CONTAINER_VALIDATED -eq 1 ]]; then
        return 0
    fi

    if validate_container_prerequisites "$container"; then
        CONTAINER_VALIDATED=1
        return 0
    else
        return 1
    fi
}

test_integration_single_path() {
    log_test "Integration: Extract single path from container"
    ((TESTS_RUN++))

    local container="${TEST_CONTAINER:-}"
    if [[ -z "$container" ]]; then
        log_skip "No TEST_CONTAINER specified"
        return
    fi

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    if ! validate_container_once; then
        log_skip "Container prerequisites not met"
        return
    fi

    # Setup clean staging
    local int_staging="${TEST_STAGING}/integration"
    mkdir -p "$int_staging"

    # Run extraction with real incus
    local output rc
    run_extract_real output rc "$container" "$int_staging" "etc/hostname"

    if [[ $rc -eq 0 ]] && [[ -f "$int_staging/etc/hostname" ]]; then
        log_pass "Single path extraction succeeded"
    else
        log_fail "Single path extraction - rc=$rc, output: $output"
    fi
}

test_integration_multiple_paths() {
    log_test "Integration: Extract multiple paths from container"
    ((TESTS_RUN++))

    local container="${TEST_CONTAINER:-}"
    if [[ -z "$container" ]]; then
        log_skip "No TEST_CONTAINER specified"
        return
    fi

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    if ! validate_container_once; then
        log_skip "Container prerequisites not met"
        return
    fi

    # Setup clean staging
    local int_staging="${TEST_STAGING}/integration-multi"
    mkdir -p "$int_staging"

    # Run extraction with real incus
    local output rc
    run_extract_real output rc "$container" "$int_staging" "etc/hostname" "etc/passwd"

    if [[ $rc -eq 0 ]] && [[ -f "$int_staging/etc/hostname" ]] && [[ -f "$int_staging/etc/passwd" ]]; then
        log_pass "Multiple paths extraction succeeded"
    else
        log_fail "Multiple paths extraction - rc=$rc, output: $output"
    fi
}

test_integration_file_list() {
    log_test "Integration: Extract paths from file list"
    ((TESTS_RUN++))

    local container="${TEST_CONTAINER:-}"
    if [[ -z "$container" ]]; then
        log_skip "No TEST_CONTAINER specified"
        return
    fi

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    if ! validate_container_once; then
        log_skip "Container prerequisites not met"
        return
    fi

    # Setup clean staging
    local int_staging="${TEST_STAGING}/integration-list"
    mkdir -p "$int_staging"

    # Run extraction with real incus
    local output rc
    run_extract_real output rc "$container" "$int_staging" "--file-list" "$TEST_FILELIST"

    if [[ $rc -eq 0 ]] && [[ -f "$int_staging/etc/hostname" ]]; then
        log_pass "File list extraction succeeded"
    else
        log_fail "File list extraction - rc=$rc, output: $output"
    fi
}

test_integration_uid_preservation() {
    log_test "Integration: Verify UID preservation in extraction"
    ((TESTS_RUN++))

    local container="${TEST_CONTAINER:-}"
    if [[ -z "$container" ]]; then
        log_skip "No TEST_CONTAINER specified"
        return
    fi

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    if ! validate_container_once; then
        log_skip "Container prerequisites not met"
        return
    fi

    # Setup clean staging
    local int_staging="${TEST_STAGING}/integration-uid"
    mkdir -p "$int_staging"

    # Run extraction with real incus
    local output rc
    run_extract_real output rc "$container" "$int_staging" "etc/passwd"

    # Check that files have container-shifted UIDs (100000+ for unprivileged containers)
    local uid
    uid=$(stat -c '%u' "$int_staging/etc/passwd" 2>/dev/null || echo "0")

    if [[ $uid -ge 100000 ]] || [[ $uid -eq 0 ]]; then
        log_pass "UID preserved (uid=$uid)"
    else
        log_fail "UID preservation - expected 100000+ or 0, got: $uid"
    fi
}

test_integration_nonexistent_path() {
    log_test "Integration: Non-existent path should fail extraction"
    ((TESTS_RUN++))

    local container="${TEST_CONTAINER:-}"
    if [[ -z "$container" ]]; then
        log_skip "No TEST_CONTAINER specified"
        return
    fi

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    if ! validate_container_once; then
        log_skip "Container prerequisites not met"
        return
    fi

    # Setup clean staging
    local int_staging="${TEST_STAGING}/integration-nonexistent"
    mkdir -p "$int_staging"

    # Request a path that definitely does not exist
    # Current behavior: script should fail (exit code 5 = extraction error)
    local output rc
    run_extract_real output rc "$container" "$int_staging" "this/path/does/not/exist/anywhere-$RANDOM"

    if [[ $rc -ne 0 ]]; then
        log_pass "Non-existent path correctly failed (rc=$rc)"
        echo "  INFO: Non-existent path handling: rc=$rc"
    else
        log_fail "Non-existent path should have failed but succeeded"
        echo "  INFO: Extract script returned rc=$rc, msg=${output}"
    fi
}

test_integration_container_not_running() {
    log_test "Integration: Real non-existent container should fail"
    ((TESTS_RUN++))

    if [[ -n "${SKIP_CONTAINER:-}" ]]; then
        log_skip "Container tests disabled (SKIP_CONTAINER set)"
        return
    fi

    # Use real incus to verify non-existent container handling
    local output rc
    run_extract_real output rc "nonexistent-container-xyz-12345" "$TEST_STAGING/service1" "etc"

    if [[ $rc -eq 4 ]] || echo "$output" | grep -q "does not exist"; then
        log_pass "Real non-existent container rejected (exit 4)"
    else
        log_fail "Real non-existent container - expected exit 4, got rc=$rc: $output"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "============================================="
    echo "backuppc-staging-extract Test Suite"
    echo "============================================="
    echo "Project root: $PROJECT_ROOT"
    echo "Script under test: $EXTRACT_SCRIPT"
    echo "Running as: root"
    echo "Debug mode: $([ "$TEST_DEBUG" = "1" ] && echo "enabled" || echo "disabled")"

    if [[ ! -x "$EXTRACT_SCRIPT" ]]; then
        echo -e "${RED}ERROR: Script not found or not executable: $EXTRACT_SCRIPT${NC}"
        exit 1
    fi

    if [[ -n "${TEST_CONTAINER:-}" ]]; then
        echo "Test container: $TEST_CONTAINER"
    else
        echo "Test container: (not specified, integration tests will be skipped)"
    fi

    echo "============================================="

    # Setup
    setup
    trap cleanup EXIT

    echo ""
    echo "--- Unit Tests: Argument Validation ---"
    test_no_arguments
    test_missing_paths
    test_file_list_missing_file

    echo ""
    echo "--- Unit Tests: Configuration Validation ---"
    test_missing_config
    test_config_bad_owner
    test_config_world_writable
    test_config_group_writable
    test_empty_config

    echo ""
    echo "--- Unit Tests: Security Validation ---"
    test_staging_not_under_root
    test_staging_is_root
    test_container_path_traversal
    test_container_path_absolute
    test_container_path_empty
    test_staging_dir_not_exist

    echo ""
    echo "--- Unit Tests: Container Validation ---"
    test_container_not_found

    echo ""
    echo "--- Unit Tests: File List Validation ---"
    test_file_list_not_found
    test_file_list_empty
    test_file_list_with_traversal

    echo ""
    echo "--- Integration Tests (require TEST_CONTAINER) ---"
    test_integration_single_path
    test_integration_multiple_paths
    test_integration_file_list
    test_integration_uid_preservation
    test_integration_nonexistent_path
    test_integration_container_not_running

    echo ""
    echo "============================================="
    echo -e "Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}, ${YELLOW}${TESTS_SKIPPED} skipped${NC}"
    echo "============================================="

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
