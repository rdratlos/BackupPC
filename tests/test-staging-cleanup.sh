#!/bin/bash
# =============================================================================
# tests/test-staging-cleanup.sh
# =============================================================================
#
# Test suite for backuppc-staging-cleanup
#
# Usage:
#   sudo ./tests/test-staging-cleanup.sh
#
# Requirements:
#   - Must run as root (sudo) to test ownership scenarios
#   - Run from project root directory
#
# The script:
#   1. Creates temporary test structures with various ownerships/permissions
#   2. Tests security validations (path checks, config security)
#   3. Tests actual cleanup operations
#   4. Cleans up after itself
#
# =============================================================================

# Explicitly NOT using set -e - we want to handle errors ourselves
set -u  # Only undefined variables are errors
set -o pipefail

# -----------------------------------------------------------------------------
# Path setup - find project root relative to this script
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLEANUP_SCRIPT="$PROJECT_ROOT/bin/backuppc-staging-cleanup"
TEST_BASE="/tmp/backuppc-staging-cleanup-test-$$"
TEST_CONFIG="$TEST_BASE/staging-roots.conf"
TEST_STAGING="$TEST_BASE/staging"

# -----------------------------------------------------------------------------
# Output formatting
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

passed=0
failed=0
skipped=0

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_test()  { echo -e "${YELLOW}[TEST]${NC} $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $*"; ((passed++)); }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; ((failed++)); }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; ((skipped++)); }

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

# Run cleanup script with test config
run_cleanup() {
    BACKUPPC_STAGING_ROOTS_CONF="$TEST_CONFIG" "$CLEANUP_SCRIPT" "$@"
}

# Expect a specific exit code - with detailed diagnostics
expect_exit() {
    local expected="$1"
    local description="$2"
    shift 2

    local output=""
    local actual=0

    # Capture both stdout and stderr, and exit code
    output=$(run_cleanup "$@" 2>&1) || actual=$?

    if [[ $actual -eq $expected ]]; then
        log_pass "$description (exit $actual)"
        return 0
    else
        log_fail "$description"
        echo "       Expected exit: $expected"
        echo "       Actual exit:   $actual"
        echo "       Command: BACKUPPC_STAGING_ROOTS_CONF=\"$TEST_CONFIG\" $CLEANUP_SCRIPT $*"
        if [[ -n "$output" ]]; then
            echo "       Output:"
            echo "$output" | sed 's/^/         /'
        fi
        return 1
    fi
}

# Expect success and verify directory is empty - with detailed diagnostics
expect_cleaned() {
    local dir="$1"
    local description="$2"

    local output=""
    local actual=0

    output=$(run_cleanup "$dir" 2>&1) || actual=$?

    if [[ $actual -ne 0 ]]; then
        log_fail "$description"
        echo "       Cleanup failed with exit: $actual"
        echo "       Directory: $dir"
        if [[ -n "$output" ]]; then
            echo "       Output:"
            echo "$output" | sed 's/^/         /'
        fi
        return 1
    fi

    # Check directory still exists
    if [[ ! -d "$dir" ]]; then
        log_fail "$description"
        echo "       Directory was removed (should only clean contents)"
        echo "       Directory: $dir"
        return 1
    fi

    # Check directory is empty
    local remaining=0
    remaining=$(find "$dir" -mindepth 1 2>/dev/null | wc -l) || true

    if [[ $remaining -eq 0 ]]; then
        log_pass "$description"
        return 0
    else
        log_fail "$description"
        echo "       Directory not empty: $remaining items remaining"
        echo "       Directory: $dir"
        echo "       Remaining items:"
        find "$dir" -mindepth 1 2>/dev/null | head -10 | sed 's/^/         /'
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Setup and teardown
# -----------------------------------------------------------------------------
setup() {
    log_info "Setting up test environment in $TEST_BASE"

    # Ensure clean state
    rm -rf "$TEST_BASE" || {
        echo "ERROR: Failed to remove old test directory: $TEST_BASE" >&2
        return 1
    }

    mkdir -p "$TEST_BASE" || {
        echo "ERROR: Failed to create test base: $TEST_BASE" >&2
        return 1
    }

    mkdir -p "$TEST_STAGING" || {
        echo "ERROR: Failed to create test staging: $TEST_STAGING" >&2
        return 1
    }

    # Create config file (root-owned, secure permissions)
    cat > "$TEST_CONFIG" << EOF
# Test staging roots configuration
$TEST_STAGING
EOF

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create test config: $TEST_CONFIG" >&2
        return 1
    fi

    chmod 644 "$TEST_CONFIG" || {
        echo "ERROR: Failed to set config permissions" >&2
        return 1
    }

    log_info "Test environment ready"
    log_info "  Config: $TEST_CONFIG"
    log_info "  Staging: $TEST_STAGING"
    return 0
}

teardown() {
    local rc=$?
    log_info "Cleaning up test environment"
    rm -rf "$TEST_BASE" 2>/dev/null || true
    return $rc
}

# -----------------------------------------------------------------------------
# Test: Prerequisites
# -----------------------------------------------------------------------------
test_prerequisites() {
    log_test "Checking prerequisites..."

    if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
        log_fail "Cleanup script not found: $CLEANUP_SCRIPT"
        echo "       Run from project root: sudo ./tests/test-staging-cleanup.sh"
        return 1
    fi

    if [[ ! -x "$CLEANUP_SCRIPT" ]]; then
        log_fail "Cleanup script not executable: $CLEANUP_SCRIPT"
        echo "       Run: chmod +x $CLEANUP_SCRIPT"
        return 1
    fi
    log_pass "Cleanup script found and executable: $CLEANUP_SCRIPT"

    u=$(id -u)
    if [[ $u -ne 0 ]]; then
        log_fail "Tests must run as root (use sudo)"
        return 1
    fi
    log_pass "Running as root"

    return 0
}

# -----------------------------------------------------------------------------
# Test: Argument validation
# -----------------------------------------------------------------------------
test_arguments() {
    log_test "Testing argument validation..."

    expect_exit 1 "No arguments" 
    expect_exit 1 "Too many arguments" /tmp/foo /tmp/bar
    expect_exit 3 "Empty string argument" ""
}

# -----------------------------------------------------------------------------
# Test: Dangerous path rejection
# -----------------------------------------------------------------------------
test_dangerous_paths() {
    log_test "Testing dangerous path rejection..."

    expect_exit 3 "Root directory (/)" /
    expect_exit 3 "Current directory (.)" .
    expect_exit 3 "Parent directory (..)" ..

    # System directories
    expect_exit 3 "System dir /etc" /etc
    expect_exit 3 "System dir /var" /var
    expect_exit 3 "System dir /home" /home
    expect_exit 3 "System dir /usr" /usr
    expect_exit 3 "System dir /bin" /bin
    expect_exit 3 "System dir /root" /root
}

# -----------------------------------------------------------------------------
# Test: Allowlist validation
# -----------------------------------------------------------------------------
test_allowlist() {
    log_test "Testing allowlist validation..."

    # Path outside any allowed root
    expect_exit 3 "Path outside allowlist" /tmp/not-in-allowlist/service/data

    # Path that looks similar but isn't under allowed root
    mkdir -p "${TEST_STAGING}-fake/service/data"
    expect_exit 3 "Similar but different path" "${TEST_STAGING}-fake/service/data"
    rm -rf "${TEST_STAGING}-fake"
}

# -----------------------------------------------------------------------------
# Test: Depth validation
# -----------------------------------------------------------------------------
test_depth() {
    log_test "Testing depth validation..."

    # Create nested structure
    mkdir -p "$TEST_STAGING/service/subdir/deep"

    # Staging root itself - not under root, should fail
    expect_exit 3 "Staging root itself" "$TEST_STAGING"

    # One level deep (depth 1) - too shallow
    expect_exit 3 "Depth 1 (too shallow)" "$TEST_STAGING/service"

    # Two levels deep (depth 2) - should pass validation
    # (will succeed even if empty)
    expect_exit 0 "Depth 2 (minimum)" "$TEST_STAGING/service/subdir"

    # Three levels deep (depth 3) - should pass
    expect_exit 0 "Depth 3" "$TEST_STAGING/service/subdir/deep"
}

# -----------------------------------------------------------------------------
# Test: Config file security
# -----------------------------------------------------------------------------
test_config_security() {
    log_test "Testing config file security..."

    # Save original state
    local orig_perms
    orig_perms=$(stat -c '%a' "$TEST_CONFIG") || {
        log_fail "Could not stat config file"
        return 1
    }

    # Test world-writable config
    chmod 666 "$TEST_CONFIG" || {
        log_fail "Could not change config permissions for test"
        return 1
    }
    expect_exit 2 "World-writable config rejected" "$TEST_STAGING/service/data" || true

    # Restore permissions
    chmod "$orig_perms" "$TEST_CONFIG" || {
        log_fail "Could not restore config permissions"
        return 1
    }

    # Test wrong ownership (only if we can change it)
    if id nobody &>/dev/null; then
        local changed=0
        chown nobody:nogroup "$TEST_CONFIG" 2>/dev/null && changed=1
        if [[ $changed -eq 0 ]]; then
            chown nobody:nobody "$TEST_CONFIG" 2>/dev/null && changed=1
        fi

        if [[ $changed -eq 1 ]]; then
            expect_exit 2 "Non-root owned config rejected" "$TEST_STAGING/service/data" || true
            chown root:root "$TEST_CONFIG" || {
                log_fail "Could not restore config ownership"
                return 1
            }
        else
            log_skip "Could not change ownership (container environment?)"
        fi
    else
        log_skip "User 'nobody' not available for ownership test"
    fi

    # Test missing config
    local saved_config="${TEST_CONFIG}.saved"
    mv "$TEST_CONFIG" "$saved_config" || {
        log_fail "Could not move config for missing config test"
        return 1
    }
    expect_exit 2 "Missing config rejected" "$TEST_STAGING/service/data" || true
    mv "$saved_config" "$TEST_CONFIG" || {
        log_fail "Could not restore config after missing config test"
        return 1
    }

    return 0
}

# -----------------------------------------------------------------------------
# Test: Symlink traversal prevention
# -----------------------------------------------------------------------------
test_symlink_traversal() {
    log_test "Testing symlink traversal prevention..."

    mkdir -p "$TEST_STAGING/evil/subdir"

    # Symlink trying to escape to /etc
    ln -sf /etc "$TEST_STAGING/evil/subdir/escape"
    expect_exit 3 "Symlink to /etc blocked" "$TEST_STAGING/evil/subdir/escape"

    # Symlink trying to escape outside staging
    ln -sf /tmp "$TEST_STAGING/evil/subdir/tmp-escape"
    expect_exit 3 "Symlink to /tmp blocked" "$TEST_STAGING/evil/subdir/tmp-escape"

    rm -rf "$TEST_STAGING/evil"
}

# -----------------------------------------------------------------------------
# Test: Non-existent target (idempotent behavior)
# -----------------------------------------------------------------------------
test_nonexistent() {
    log_test "Testing non-existent target handling..."

    # Valid path structure but doesn't exist
    expect_exit 0 "Non-existent valid path returns success" "$TEST_STAGING/nonexistent/service"
}

# -----------------------------------------------------------------------------
# Test: Successful cleanup scenarios
# -----------------------------------------------------------------------------
test_cleanup_basic() {
    log_test "Testing basic cleanup..."

    # Setup: Create directory with files
    local target="$TEST_STAGING/service1/data"
    mkdir -p "$target"
    echo "test content" > "$target/file.txt"
    echo "more content" > "$target/another.txt"
    mkdir -p "$target/subdir"
    echo "nested" > "$target/subdir/nested.txt"

    expect_cleaned "$target" "Basic cleanup with files and subdirs"
}

test_cleanup_hidden_files() {
    log_test "Testing cleanup of hidden files..."

    local target="$TEST_STAGING/service2/config"
    mkdir -p "$target"
    echo "visible" > "$target/visible.conf"
    echo "hidden" > "$target/.hidden"
    echo "also hidden" > "$target/.dotfile.conf"
    mkdir -p "$target/.hidden-dir"
    echo "in hidden dir" > "$target/.hidden-dir/file"

    expect_cleaned "$target" "Cleanup including hidden files and dirs"
}

test_cleanup_special_names() {
    log_test "Testing cleanup of files with special names..."

    local target="$TEST_STAGING/service3/data"
    mkdir -p "$target"

    # Files with spaces
    echo "space" > "$target/file with spaces.txt"

    # Files with special characters (that are valid in filenames)
    echo "special" > "$target/file-with-dashes.txt"
    echo "special" > "$target/file_with_underscores.txt"
    echo "special" > "$target/file.multiple.dots.txt"

    # Files starting with dash
    echo "dash" > "$target/-dashfile"

    expect_cleaned "$target" "Cleanup with special filenames"
}

test_cleanup_shifted_ownership() {
    log_test "Testing cleanup of container-shifted ownership..."

    local target="$TEST_STAGING/service4/container-data"
    mkdir -p "$target"

    # Simulate container-shifted UIDs (100000+ range)
    echo "shifted" > "$target/shifted-file.txt"
    mkdir -p "$target/shifted-dir"
    echo "nested shifted" > "$target/shifted-dir/nested.txt"

    # Change ownership to simulate unprivileged container mapping
    chown -R 100033:100033 "$target"

    expect_cleaned "$target" "Cleanup with shifted UIDs (100033:100033)"
}

test_cleanup_readonly_files() {
    log_test "Testing cleanup of read-only files..."

    local target="$TEST_STAGING/service5/readonly"
    mkdir -p "$target"

    echo "readonly" > "$target/readonly.txt"
    chmod 444 "$target/readonly.txt"

    mkdir -p "$target/readonly-dir"
    echo "in readonly" > "$target/readonly-dir/file.txt"
    chmod 555 "$target/readonly-dir"

    expect_cleaned "$target" "Cleanup with read-only files and dirs"
}

test_cleanup_preserves_siblings() {
    log_test "Testing that cleanup preserves sibling directories..."

    # Create two sibling directories
    mkdir -p "$TEST_STAGING/service6/target" || {
        log_fail "Could not create target directory"
        return 1
    }
    mkdir -p "$TEST_STAGING/service6/sibling" || {
        log_fail "Could not create sibling directory"
        return 1
    }

    echo "target file" > "$TEST_STAGING/service6/target/file.txt" || {
        log_fail "Could not create target file"
        return 1
    }
    echo "sibling file" > "$TEST_STAGING/service6/sibling/keep-me.txt" || {
        log_fail "Could not create sibling file"
        return 1
    }

    # Clean only target
    local output=""
    local rc=0
    output=$(run_cleanup "$TEST_STAGING/service6/target" 2>&1) || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_fail "Cleanup of target failed (exit $rc)"
        echo "       Output: $output"
        return 1
    fi

    # Verify sibling is untouched
    if [[ -f "$TEST_STAGING/service6/sibling/keep-me.txt" ]]; then
        log_pass "Sibling directory preserved"
        return 0
    else
        log_fail "Sibling directory was incorrectly modified"
        echo "       Expected file missing: $TEST_STAGING/service6/sibling/keep-me.txt"
        echo "       Sibling directory contents:"
        ls -la "$TEST_STAGING/service6/sibling" 2>&1 | sed 's/^/         /' || echo "         (directory missing)"
        return 1
    fi
}

test_cleanup_deep_nesting() {
    log_test "Testing cleanup of deeply nested structures..."

    local target="$TEST_STAGING/service7/deep"
    mkdir -p "$target/a/b/c/d/e/f/g/h/i/j"
    echo "deep file" > "$target/a/b/c/d/e/f/g/h/i/j/deep.txt"

    # Also add files at various levels
    echo "level a" > "$target/a/file-a.txt"
    echo "level c" > "$target/a/b/c/file-c.txt"
    echo "level f" > "$target/a/b/c/d/e/f/file-f.txt"

    expect_cleaned "$target" "Cleanup of deeply nested structure (10 levels)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "============================================="
    echo "backuppc-staging-cleanup Test Suite"
    echo "============================================="
    echo "Project root: $PROJECT_ROOT"
    echo "Script under test: $CLEANUP_SCRIPT"
    echo "============================================="
    echo ""

    # Check prerequisites first - exit if they fail
    if ! test_prerequisites; then
        echo ""
        echo "Prerequisites failed - cannot continue"
        exit 1
    fi

    # Setup test environment
    if ! setup; then
        echo ""
        echo "Setup failed - cannot continue"
        exit 1
    fi

    # Register teardown (but don't use trap for error handling)
    trap teardown EXIT

    echo ""
    echo "--- Security Validation Tests ---"
    test_arguments || true
    test_dangerous_paths || true
    test_allowlist || true
    test_depth || true
    test_config_security || true
    test_symlink_traversal || true
    test_nonexistent || true

    echo ""
    echo "--- Cleanup Operation Tests ---"
    test_cleanup_basic || true
    test_cleanup_hidden_files || true
    test_cleanup_special_names || true
    test_cleanup_shifted_ownership || true
    test_cleanup_readonly_files || true
    test_cleanup_preserves_siblings || true
    test_cleanup_deep_nesting || true

    echo ""
    echo "============================================="
    echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
    echo "============================================="

    if [[ $failed -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
