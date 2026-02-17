#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Test Suite Runner
#  Sends real coding jobs to the OpenClaw agent and validates the output.
#  Usage: ./tests/run-all.sh [test-name]
#    No args = run all tests sequentially
#    test-name = run a single test (e.g., "tetris", "pong", "smashtv", "todo", "api")
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"

TEST_OUTPUT_DIR="/tmp/tritium-tests"
GATEWAY_PORT=18789
AGENT_TIMEOUT=600  # 10 minutes per test

# Colors for test results
PASS="${BGRN}PASS${RST}"
FAIL="${BRED}FAIL${RST}"
SKIP="${DIM}SKIP${RST}"

passed=0
failed=0
skipped=0
results=()

# -------------------------------------------------------------------------
#  Helpers
# -------------------------------------------------------------------------

preflight() {
    # Check Ollama
    if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
        echo -e "  ${BRED}Ollama is not running.${RST} Run ${CYN}./start.sh${RST} first."
        exit 1
    fi
    # Check gateway
    if ! ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        echo -e "  ${BRED}OpenClaw gateway is not running.${RST} Run ${CYN}./start.sh${RST} first."
        exit 1
    fi
    log_ok "Preflight checks passed"
}

run_agent_job() {
    local session_id="$1"
    local prompt="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    export OPENCLAW_GATEWAY_TOKEN="tritium-local-dev"
    export OLLAMA_API_KEY="ollama-local"

    openclaw agent \
        --local \
        --session-id "$session_id" \
        --message "$prompt" \
        --thinking medium \
        --timeout "$AGENT_TIMEOUT" \
        > "$output_dir/agent-output.log" 2>&1 || true
}

check_file_exists() {
    local filepath="$1"
    local description="$2"
    if [ -f "$filepath" ]; then
        log_ok "$description"
        return 0
    else
        log_fail "$description — file not found: $filepath"
        return 1
    fi
}

check_file_contains() {
    local filepath="$1"
    local pattern="$2"
    local description="$3"
    if grep -q "$pattern" "$filepath" 2>/dev/null; then
        log_ok "$description"
        return 0
    else
        log_fail "$description — pattern '$pattern' not found in $filepath"
        return 1
    fi
}

check_file_min_size() {
    local filepath="$1"
    local min_bytes="$2"
    local description="$3"
    if [ -f "$filepath" ]; then
        local size
        size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
        if [ "$size" -ge "$min_bytes" ]; then
            log_ok "$description (${size} bytes)"
            return 0
        else
            log_fail "$description — file too small: ${size} bytes (expected >= ${min_bytes})"
            return 1
        fi
    else
        log_fail "$description — file not found"
        return 1
    fi
}

record_result() {
    local test_name="$1"
    local status="$2"
    results+=("$status  $test_name")
    if [ "$status" = "PASS" ]; then
        passed=$((passed + 1))
    elif [ "$status" = "FAIL" ]; then
        failed=$((failed + 1))
    else
        skipped=$((skipped + 1))
    fi
}

# -------------------------------------------------------------------------
#  Test Definitions
# -------------------------------------------------------------------------

test_todo() {
    local name="todo"
    local dir="$TEST_OUTPUT_DIR/$name"
    section "Test: Flask Todo App"

    local prompt="Create a Python Flask todo app in $dir/. Requirements:
- Single file: app.py
- Use SQLite for storage (db file in same directory)
- Inline HTML template (no separate template files)
- Features: add todo, mark complete, delete todo
- Clean CSS styling inline in the HTML
- Run on port 5001
Write the complete app.py file. Do not run it."

    log_run "Sending job to agent..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true
    check_file_exists "$dir/app.py" "app.py exists" || ok=false
    check_file_min_size "$dir/app.py" 1000 "app.py has substantial code" || ok=false
    check_file_contains "$dir/app.py" "flask\|Flask" "app.py imports Flask" || ok=false
    check_file_contains "$dir/app.py" "sqlite3\|SQLite\|sqlite" "app.py uses SQLite" || ok=false
    check_file_contains "$dir/app.py" "def.*add\|/add\|add_todo\|add.*todo" "app.py has add endpoint" || ok=false
    check_file_contains "$dir/app.py" "def.*delete\|/delete\|delete_todo" "app.py has delete endpoint" || ok=false

    # Syntax check
    if python3 -c "import py_compile; py_compile.compile('$dir/app.py', doraise=True)" 2>/dev/null; then
        log_ok "app.py passes Python syntax check"
    else
        log_fail "app.py has syntax errors"
        ok=false
    fi

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

test_api() {
    local name="api"
    local dir="$TEST_OUTPUT_DIR/$name"
    section "Test: REST API (Bookstore)"

    local prompt="Create a Python Flask REST API for a bookstore in $dir/. Requirements:
- Single file: api.py
- Use SQLite for storage
- Endpoints: GET /books, GET /books/<id>, POST /books, PUT /books/<id>, DELETE /books/<id>
- Book fields: id, title, author, year, isbn
- Return JSON responses with proper status codes
- Include seed data (3-5 books inserted on first run)
- Run on port 5002
Write the complete api.py file. Do not run it."

    log_run "Sending job to agent..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true
    check_file_exists "$dir/api.py" "api.py exists" || ok=false
    check_file_min_size "$dir/api.py" 1500 "api.py has substantial code" || ok=false
    check_file_contains "$dir/api.py" "flask\|Flask" "api.py imports Flask" || ok=false
    check_file_contains "$dir/api.py" "GET\|get\|books" "api.py has books endpoints" || ok=false
    check_file_contains "$dir/api.py" "POST\|post\|create\|add" "api.py has create endpoint" || ok=false
    check_file_contains "$dir/api.py" "DELETE\|delete" "api.py has delete endpoint" || ok=false
    check_file_contains "$dir/api.py" "jsonify\|json" "api.py returns JSON" || ok=false

    if python3 -c "import py_compile; py_compile.compile('$dir/api.py', doraise=True)" 2>/dev/null; then
        log_ok "api.py passes Python syntax check"
    else
        log_fail "api.py has syntax errors"
        ok=false
    fi

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

test_tetris() {
    local name="tetris"
    local dir="$TEST_OUTPUT_DIR/$name"
    section "Test: Tetris Web Game"

    local prompt="Create a Tetris web game in $dir/. Requirements:
- Single file: index.html (all HTML, CSS, and JavaScript inline)
- Full Tetris gameplay: falling pieces, rotation, line clearing, scoring
- All 7 standard tetrominoes (I, O, T, S, Z, J, L)
- Keyboard controls: arrow keys for move/rotate, space for hard drop
- Score display and game over detection
- Clean visual design with a grid board
- No external dependencies — pure HTML5 Canvas or DOM-based rendering
Write the complete index.html file."

    log_run "Sending job to agent..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true
    check_file_exists "$dir/index.html" "index.html exists" || ok=false
    check_file_min_size "$dir/index.html" 3000 "index.html has substantial code" || ok=false
    check_file_contains "$dir/index.html" "<canvas\|canvas\|getElementById" "Uses canvas or DOM rendering" || ok=false
    check_file_contains "$dir/index.html" "keydown\|keyCode\|key ==\|addEventListener" "Has keyboard controls" || ok=false
    check_file_contains "$dir/index.html" "score\|Score\|SCORE" "Has scoring" || ok=false
    check_file_contains "$dir/index.html" "rotate\|Rotate\|ROTATE" "Has rotation logic" || ok=false
    check_file_contains "$dir/index.html" "game.*over\|Game.*Over\|GAME.*OVER\|gameOver" "Has game over detection" || ok=false

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

test_pong() {
    local name="pong"
    local dir="$TEST_OUTPUT_DIR/$name"
    section "Test: Pong Web Game"

    local prompt="Create a Pong game in $dir/. Requirements:
- Single file: index.html (all HTML, CSS, and JavaScript inline)
- Two-player mode: Player 1 uses W/S keys, Player 2 uses Up/Down arrows
- Also include an AI opponent mode (toggle with a button)
- Ball physics: angle changes based on where it hits the paddle
- Score tracking for both players, first to 10 wins
- Clean retro visual style (dark background, white elements)
- No external dependencies — pure HTML5 Canvas
Write the complete index.html file."

    log_run "Sending job to agent..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true
    check_file_exists "$dir/index.html" "index.html exists" || ok=false
    check_file_min_size "$dir/index.html" 2000 "index.html has substantial code" || ok=false
    check_file_contains "$dir/index.html" "<canvas\|canvas" "Uses canvas rendering" || ok=false
    check_file_contains "$dir/index.html" "keydown\|keyCode\|key ==\|addEventListener" "Has keyboard controls" || ok=false
    check_file_contains "$dir/index.html" "ball\|Ball\|BALL" "Has ball object" || ok=false
    check_file_contains "$dir/index.html" "paddle\|Paddle\|PADDLE\|player" "Has paddle/player objects" || ok=false
    check_file_contains "$dir/index.html" "score\|Score\|SCORE" "Has scoring" || ok=false
    check_file_contains "$dir/index.html" "AI\|ai\|computer\|Computer\|opponent" "Has AI opponent" || ok=false

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

test_smashtv() {
    local name="smashtv"
    local dir="$TEST_OUTPUT_DIR/$name"
    section "Test: Smash TV Web Game"

    local prompt="Create a Smash TV-style twin-stick arena shooter in $dir/. Requirements:
- Single file: index.html (all HTML, CSS, and JavaScript inline)
- Top-down arena view with HTML5 Canvas
- Player movement with WASD keys
- Shooting direction follows mouse cursor, click or hold to fire
- Waves of enemies that spawn from arena edges and chase the player
- Enemies killed on contact with bullets, player takes damage on enemy contact
- Power-ups that spawn randomly: health, spread shot, speed boost
- HUD: health bar, score, wave number, kill count
- Increasing difficulty each wave (more enemies, faster movement)
- Retro arcade visual style with bright colors on dark background
- Game over screen with final score
- No external dependencies — pure HTML5 Canvas and vanilla JavaScript
Write the complete index.html file."

    log_run "Sending job to agent..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true
    check_file_exists "$dir/index.html" "index.html exists" || ok=false
    check_file_min_size "$dir/index.html" 5000 "index.html has substantial code (complex game)" || ok=false
    check_file_contains "$dir/index.html" "<canvas\|canvas" "Uses canvas rendering" || ok=false
    check_file_contains "$dir/index.html" "keydown\|keyCode\|addEventListener" "Has keyboard input" || ok=false
    check_file_contains "$dir/index.html" "mouse\|Mouse\|click\|Click\|mousedown\|mousemove" "Has mouse input" || ok=false
    check_file_contains "$dir/index.html" "enem\|Enem\|ENEM" "Has enemy logic" || ok=false
    check_file_contains "$dir/index.html" "bullet\|Bullet\|BULLET\|projectile\|shoot" "Has bullet/shooting" || ok=false
    check_file_contains "$dir/index.html" "score\|Score\|SCORE" "Has scoring" || ok=false
    check_file_contains "$dir/index.html" "wave\|Wave\|WAVE\|level\|Level" "Has wave/level system" || ok=false
    check_file_contains "$dir/index.html" "health\|Health\|HEALTH\|hp\|HP\|life\|damage" "Has health system" || ok=false
    check_file_contains "$dir/index.html" "power.*up\|Power.*up\|powerup\|bonus\|pickup" "Has power-ups" || ok=false

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

# -------------------------------------------------------------------------
#  Main
# -------------------------------------------------------------------------

banner
section "Tritium Coder Test Suite"

echo -e "  ${DIM}Output directory: $TEST_OUTPUT_DIR${RST}"
echo -e "  ${DIM}Agent timeout:    ${AGENT_TIMEOUT}s per test${RST}"
echo ""

preflight

# Clean previous test output
rm -rf "$TEST_OUTPUT_DIR"
mkdir -p "$TEST_OUTPUT_DIR"

# Run tests
FILTER="${1:-all}"

if [ "$FILTER" = "all" ]; then
    TESTS=(todo api tetris pong smashtv)
else
    TESTS=("$FILTER")
fi

START_TIME=$(date +%s)

for test in "${TESTS[@]}"; do
    case "$test" in
        todo)    test_todo ;;
        api)     test_api ;;
        tetris)  test_tetris ;;
        pong)    test_pong ;;
        smashtv) test_smashtv ;;
        *)
            log_warn "Unknown test: $test"
            record_result "$test" "SKIP"
            ;;
    esac
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

# -------------------------------------------------------------------------
#  Summary
# -------------------------------------------------------------------------
section "Test Results"

for r in "${results[@]}"; do
    status="${r%% *}"
    name="${r#* }"
    case "$status" in
        PASS) echo -e "  ${PASS}  $name" ;;
        FAIL) echo -e "  ${FAIL}  $name" ;;
        SKIP) echo -e "  ${SKIP}  $name" ;;
    esac
done

echo ""
TOTAL=$((passed + failed + skipped))
echo -e "  ${BOLD}Total:${RST} $TOTAL  ${BGRN}Passed:${RST} $passed  ${BRED}Failed:${RST} $failed  ${DIM}Skipped:${RST} $skipped"
echo -e "  ${DIM}Time: ${ELAPSED}s${RST}"
echo ""

# List generated files
section "Generated Files"
if [ -d "$TEST_OUTPUT_DIR" ]; then
    for test_dir in "$TEST_OUTPUT_DIR"/*/; do
        if [ -d "$test_dir" ]; then
            test_name=$(basename "$test_dir")
            file_count=$(find "$test_dir" -type f -not -name "agent-output.log" 2>/dev/null | wc -l)
            total_size=$(du -sh "$test_dir" 2>/dev/null | cut -f1)
            echo -e "  ${CYN}$test_name/${RST}  ${DIM}${file_count} file(s), ${total_size}${RST}"
            find "$test_dir" -type f -not -name "agent-output.log" 2>/dev/null | while read -r f; do
                echo -e "    ${DIM}$(basename "$f")${RST}"
            done
        fi
    done
fi

echo ""
echo -e "  ${BOLD}To view a game:${RST}"
echo -e "    ${CYN}python3 -m http.server 8080 -d $TEST_OUTPUT_DIR/tetris${RST}"
echo -e "    Then open ${CYN}http://localhost:8080${RST}"
echo ""

# Exit with failure if any tests failed
[ "$failed" -eq 0 ]
