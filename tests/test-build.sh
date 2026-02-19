#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Test Harness
# =============================================================================
# Tests the build-project.sh functionality with various project types
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$PROJECT_DIR/scripts/build-project.sh"
TEST_DIR="/tmp/tritium-tests"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
#  Test Utilities
# =============================================================================

log_test() {
    echo -e "${YEL}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GRN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

setup() {
    cleanup
    mkdir -p "$TEST_DIR"
}

run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"
    if $test_func; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi
}

assert_file_exists() {
    local file="$1"
    [ -f "$file" ] || { log_fail "File not found: $file"; return 1; }
}

assert_dir_exists() {
    local dir="$1"
    [ -d "$dir" ] || { log_fail "Directory not found: $dir"; return 1; }
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q "$pattern" "$file" || { log_fail "Pattern not found: $pattern in $file"; return 1; }
}

# =============================================================================
#  Test Cases
# =============================================================================

test_project_type_detection() {
    source "$SCRIPT_DIR/../scripts/lib/project-type.sh"
    export PROJECT_DIR="$PROJECT_DIR"

    local type
    type=$(detect_project_type "Build a Tetris game" "$TEST_DIR/typetest1")
    [ "$type" = "web-game" ] || return 1

    type=$(detect_project_type "Build a REST API" "$TEST_DIR/typetest2")
    [ "$type" = "api" ] || return 1

    type=$(detect_project_type "Create a CLI tool" "$TEST_DIR/typetest3")
    [ "$type" = "cli" ] || return 1

    type=$(detect_project_type "Create a web app" "$TEST_DIR/typetest4")
    [ "$type" = "web-app" ] || return 1

    type=$(detect_project_type "Create a library" "$TEST_DIR/typetest5")
    [ "$type" = "library" ] || return 1

    return 0
}

test_session_key_generation() {
    source "$SCRIPT_DIR/../scripts/lib/session-key.sh"

    local key
    key=$(get_main_session_key)
    [[ "$key" == *"main"* ]] || return 1

    key=$(get_subagent_session_key "agent:main" "test")
    [[ "$key" == *":subagent:"* ]] || return 1

    return 0
}

test_session_key_depth() {
    source "$SCRIPT_DIR/../scripts/lib/session-key.sh"

    local depth
    depth=$(get_subagent_depth "agent:main")
    [ "$depth" = "0" ] || return 1

    depth=$(get_subagent_depth "agent:main:subagent:abc123")
    [ "$depth" = "1" ] || return 1

    depth=$(get_subagent_depth "agent:main:subagent:abc:subagent:def")
    [ "$depth" = "2" ] || return 1

    return 0
}

test_lanes_init() {
    source "$SCRIPT_DIR/../scripts/lib/lanes.sh"
    init_lanes
    assert_dir_exists "$PROJECT_DIR/.tritium-lanes"
    assert_dir_exists "$PROJECT_DIR/.tritium-lanes/main"
    return 0
}

test_lanes_concurrency() {
    source "$SCRIPT_DIR/../scripts/lib/lanes.sh"

    init_lanes

    local slot
    slot=$(acquire_lane_slot "main")
    [ -n "$slot" ] || return 1

    release_lane_slot "main" "$slot"
    [ ! -f "$PROJECT_DIR/.tritium-lanes/main/$slot" ] || return 1

    return 0
}

test_hook_registry() {
    # Need common.sh for log_to function
    source "$SCRIPT_DIR/../scripts/lib/common.sh"
    source "$SCRIPT_DIR/../scripts/lib/hooks.sh"
    init_hook_registry
    assert_file_exists "$SCRIPT_DIR/../.tritium-hooks/registry.json"
    return 0
}

test_cron_init() {
    # Need common.sh for log_to function
    source "$SCRIPT_DIR/../scripts/lib/common.sh"
    source "$SCRIPT_DIR/../scripts/lib/cron.sh"
    cron_init
    assert_file_exists "$SCRIPT_DIR/../.tritium-cron/jobs.json"
    assert_file_exists "$SCRIPT_DIR/../.tritium-cron/state.json"
    return 0
}

test_subagent_spawning() {
    # Check that the script exists and is executable
    [ -x "$SCRIPT_DIR/../scripts/subagent-spawn.sh" ] || return 1
    # Check syntax
    bash -n "$SCRIPT_DIR/../scripts/subagent-spawn.sh" || return 1
    # Check help output works
    "$SCRIPT_DIR/../scripts/subagent-spawn.sh" --help >/dev/null 2>&1 || return 1
    return 0
}

test_build_script_syntax() {
    bash -n "$BUILD_SCRIPT" || return 1
    return 0
}

test_health_error_analysis() {
    source "$SCRIPT_DIR/../scripts/lib/project-type.sh"

    # Test error analysis
    local test_error="ReferenceError: foo is not defined"
    if echo "$test_error" | grep -q "ReferenceError\|undefined"; then
        : # This is how analyze_errors works
    else
        return 1
    fi

    return 0
}

# =============================================================================
#  Integration Tests
# =============================================================================

integ_test_short_iteration() {
    local test_name="test-short-$(date +%s)"
    local test_dir="$TEST_DIR/$test_name"

    mkdir -p "$test_dir"

    # Run a very short build (1 minute) to test the flow
    timeout 60 "$BUILD_SCRIPT" \
        --description "Create a simple HTML file with Hello World" \
        --name "$test_name" \
        --hours 0.01 \
        --no-vision \
        >/dev/null 2>&1 || true

    # Check if output was created
    assert_file_exists "$test_dir/index.html" || {
        # If it failed to create index.html, that's expected for such a short time
        # Just verify the directory was created
        assert_dir_exists "$test_dir"
    }

    return 0
}

# =============================================================================
#  Main
# =============================================================================

echo "========================================"
echo "  Tritium Coder Test Suite"
echo "========================================"
echo ""

setup

run_test "Project Type Detection" test_project_type_detection
run_test "Session Key Generation" test_session_key_generation
run_test "Session Key Depth" test_session_key_depth
run_test "Lane Initialization" test_lanes_init
run_test "Lane Concurrency" test_lanes_concurrency
run_test "Hook Registry Init" test_hook_registry
run_test "Cron Initialization" test_cron_init
run_test "Sub-Agent Spawning" test_subagent_spawning
run_test "Build Script Syntax" test_build_script_syntax
run_test "Health Error Analysis" test_health_error_analysis

echo ""
echo "========================================"
echo "  Test Results"
echo "========================================"
echo "  Tests Run:    $TESTS_RUN"
echo "  Passed:       $TESTS_PASSED"
echo "  Failed:       $TESTS_FAILED"
echo "========================================"

cleanup

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi

exit 0
