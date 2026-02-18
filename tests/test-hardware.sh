#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Hardware Detection Tests
#  Tests the detect_* and get_* functions in scripts/lib/common.sh.
#  Runs on any machine — validates return types and tier logic.
#
#  Usage: ./tests/test-hardware.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local name="$1" result="$2" expected="$3"
    TOTAL=$(( TOTAL + 1 ))
    if [ "$result" = "$expected" ]; then
        echo -e "  ${SYM_OK}  ${name}"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${SYM_FAIL}  ${RED}${name}${RST}  (got '${result}', expected '${expected}')"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_numeric() {
    local name="$1" result="$2"
    TOTAL=$(( TOTAL + 1 ))
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo -e "  ${SYM_OK}  ${name}  ${DIM}(${result})${RST}"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${SYM_FAIL}  ${RED}${name}${RST}  (got '${result}', expected integer)"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_nonempty() {
    local name="$1" result="$2"
    TOTAL=$(( TOTAL + 1 ))
    if [ -n "$result" ]; then
        echo -e "  ${SYM_OK}  ${name}  ${DIM}(${result})${RST}"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${SYM_FAIL}  ${RED}${name}${RST}  (empty)"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_oneof() {
    local name="$1" result="$2"
    shift 2
    local valid=("$@")
    TOTAL=$(( TOTAL + 1 ))
    for v in "${valid[@]}"; do
        if [ "$result" = "$v" ]; then
            echo -e "  ${SYM_OK}  ${name}  ${DIM}(${result})${RST}"
            PASS=$(( PASS + 1 ))
            return
        fi
    done
    echo -e "  ${SYM_FAIL}  ${RED}${name}${RST}  (got '${result}', expected one of: ${valid[*]})"
    FAIL=$(( FAIL + 1 ))
}

banner
echo -e "  ${BOLD}Hardware Detection Tests${RST}"
echo ""

# =========================================================================
section "Return type tests"
# =========================================================================

assert_numeric "detect_ram_gb returns integer" "$(detect_ram_gb)"
assert_numeric "detect_vram_mb returns integer" "$(detect_vram_mb)"
assert_numeric "detect_available_memory_gb returns integer" "$(detect_available_memory_gb)"
assert_numeric "detect_disk_gb returns integer" "$(detect_disk_gb)"
assert_oneof "detect_unified_memory returns true/false" "$(detect_unified_memory)" "true" "false"
assert_oneof "detect_hw_tier returns valid tier" "$(detect_hw_tier)" "full" "mid" "low" "insufficient"
assert_nonempty "get_ollama_url returns a URL" "$(get_ollama_url)"

# =========================================================================
section "Value sanity tests"
# =========================================================================

RAM=$(detect_ram_gb)
DISK=$(detect_disk_gb)
AVAIL=$(detect_available_memory_gb)

# RAM should be at least 1 GB on any machine running this
TOTAL=$(( TOTAL + 1 ))
if [ "$RAM" -ge 1 ]; then
    echo -e "  ${SYM_OK}  RAM >= 1 GB  ${DIM}(${RAM} GB)${RST}"
    PASS=$(( PASS + 1 ))
else
    echo -e "  ${SYM_FAIL}  ${RED}RAM >= 1 GB${RST}  (got ${RAM})"
    FAIL=$(( FAIL + 1 ))
fi

# Disk should be at least 1 GB
TOTAL=$(( TOTAL + 1 ))
if [ "$DISK" -ge 1 ]; then
    echo -e "  ${SYM_OK}  Disk >= 1 GB  ${DIM}(${DISK} GB)${RST}"
    PASS=$(( PASS + 1 ))
else
    echo -e "  ${SYM_FAIL}  ${RED}Disk >= 1 GB${RST}  (got ${DISK})"
    FAIL=$(( FAIL + 1 ))
fi

# Available memory should be > 0 on any machine with a GPU or RAM
TOTAL=$(( TOTAL + 1 ))
if [ "$AVAIL" -ge 0 ]; then
    echo -e "  ${SYM_OK}  Available memory >= 0 GB  ${DIM}(${AVAIL} GB)${RST}"
    PASS=$(( PASS + 1 ))
else
    echo -e "  ${SYM_FAIL}  ${RED}Available memory >= 0 GB${RST}  (got ${AVAIL})"
    FAIL=$(( FAIL + 1 ))
fi

# =========================================================================
section "Tier logic tests"
# =========================================================================

# Test tier thresholds by overriding detect_available_memory_gb
test_tier() {
    local _test_gb="$1" expected="$2"
    detect_available_memory_gb() { echo "$_test_gb"; }
    local result
    result=$(detect_hw_tier)
    assert "tier for ${_test_gb} GB = ${expected}" "$result" "$expected"
}

test_tier 0 "insufficient"
test_tier 8 "insufficient"
test_tier 15 "insufficient"
test_tier 16 "low"
test_tier 24 "low"
test_tier 31 "low"
test_tier 32 "mid"
test_tier 64 "mid"
test_tier 95 "mid"
test_tier 96 "full"
test_tier 128 "full"
test_tier 256 "full"

# =========================================================================
section "get_ollama_url tests"
# =========================================================================

# Default (no OLLAMA_HOST)
(
    unset OLLAMA_HOST 2>/dev/null || true
    assert "default URL is localhost" "$(get_ollama_url)" "http://localhost:11434"
)

# With OLLAMA_HOST set
(
    export OLLAMA_HOST="http://100.64.0.1:11434"
    assert "OLLAMA_HOST overrides URL" "$(get_ollama_url)" "http://100.64.0.1:11434"
)

# =========================================================================
section "GPU detection tests"
# =========================================================================

GPU=$(detect_gpu_name)
if [ -n "$GPU" ]; then
    assert_nonempty "detect_gpu_name found GPU" "$GPU"

    UNIFIED=$(detect_unified_memory)
    if [ "$UNIFIED" = "true" ]; then
        echo -e "  ${SYM_OK}  Unified memory system — available memory uses RAM  ${DIM}(${AVAIL} GB)${RST}"
    else
        VRAM=$(detect_vram_mb)
        echo -e "  ${SYM_OK}  Discrete GPU — VRAM used for available memory  ${DIM}(${VRAM} MB)${RST}"
    fi
else
    echo -e "  ${SYM_INFO}  ${DIM}No GPU detected — GPU tests skipped${RST}"
fi

# =========================================================================
#  Summary
# =========================================================================
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
if [ "$FAIL" -eq 0 ]; then
    echo -e "  |${RST}  ${BGRN}All ${TOTAL} tests passed${RST}                                         ${BMAG}|"
else
    echo -e "  |${RST}  ${BRED}${FAIL} of ${TOTAL} tests failed${RST}                                          ${BMAG}|"
fi
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""

exit "$FAIL"
