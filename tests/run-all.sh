#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Test Suite Runner
#  Sends real coding jobs to Claude Code and validates the output.
#  Usage: ./tests/run-all.sh [test-name]
#    No args = run all tests sequentially
#    test-name = run a single test (e.g., "tetris", "pong", "smashtv", "todo", "api")
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}./test${RST} — Run the coding test suite"
    echo ""
    echo -e "  Sends real coding jobs to Claude Code and validates the output."
    echo -e "  Each test asks the agent to build a project, then checks the generated"
    echo -e "  files for correctness (file existence, size, key patterns, syntax)."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./test [test-name]"
    echo ""
    echo -e "  ${BOLD}Arguments:${RST}"
    echo -e "    ${CYN}(none)${RST}     Run all tests sequentially"
    echo -e "    ${CYN}todo${RST}       Flask todo app (simplest)"
    echo -e "    ${CYN}api${RST}        REST API bookstore"
    echo -e "    ${CYN}tetris${RST}     Tetris web game"
    echo -e "    ${CYN}pong${RST}       Pong web game"
    echo -e "    ${CYN}smashtv${RST}    Smash TV arena shooter (largest, 5-15 min)"
    echo ""
    echo -e "  ${BOLD}Examples:${RST}"
    echo -e "    ./test              Run all tests"
    echo -e "    ./test tetris       Run just the Tetris test"
    echo ""
    echo -e "  ${BOLD}Requires:${RST}  Stack must be running (${CYN}./start${RST} first)"
    echo -e "  ${BOLD}Output:${RST}    /tmp/tritium-tests/"
    echo ""
    exit 0
fi

TEST_OUTPUT_DIR="/tmp/tritium-tests"
AGENT_TIMEOUT=900  # 15 minutes per test (smash TV may use the full budget)

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
    if ! curl_check http://localhost:11434/api/tags &>/dev/null; then
        echo -e "  ${BRED}Ollama is not running.${RST} Run ${CYN}./start${RST} first."
        exit 1
    fi
    # Check proxy
    if ! ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        echo -e "  ${BRED}Claude Code proxy is not running.${RST} Run ${CYN}./start${RST} first."
        exit 1
    fi
    # Check Claude Code CLI
    if ! command -v claude &>/dev/null; then
        echo -e "  ${BRED}Claude Code CLI not found.${RST} Install: ${CYN}npm i -g @anthropic-ai/claude-code${RST}"
        exit 1
    fi
    log_ok "Preflight checks passed"
}

run_agent_job() {
    local session_id="$1"
    local prompt="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT:-8082}" \
    ANTHROPIC_API_KEY="local-model" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    timeout "$AGENT_TIMEOUT" claude -p "$prompt" \
        --dangerously-skip-permissions \
        -d "$output_dir" \
        --output-format text \
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
    section "Test: Smash TV Arena Shooter (Large Project)"

    local prompt="Build a complete Smash TV-style twin-stick arena shooter web game in $dir/.

This is a LARGE multi-file project. Take your time and build it properly.

FILE STRUCTURE:
  $dir/index.html     - Main HTML entry point, loads all JS/CSS
  $dir/css/style.css  - All game styling, HUD layout, menus
  $dir/js/game.js     - Main game loop, state machine, initialization
  $dir/js/player.js   - Player class: movement (WASD), health, lives, invincibility frames
  $dir/js/enemies.js  - Enemy classes: Grunt (chases), Sniper (shoots), Tank (high HP), Boss
  $dir/js/weapons.js  - Weapon system: pistol, shotgun (spread), laser (beam), rocket (AoE)
  $dir/js/powerups.js - Power-up drops: health, weapon upgrade, speed boost, shield, nuke
  $dir/js/waves.js    - Wave manager: spawn patterns, difficulty scaling, boss waves every 5
  $dir/js/particles.js - Particle effects: explosions, bullet trails, damage numbers, sparks
  $dir/js/hud.js      - HUD rendering: health bar, score, wave, kill count, weapon indicator, combo meter
  $dir/js/audio.js    - Sound manager using Web Audio API: shoot, explode, pickup, damage, wave-start
  $dir/js/input.js    - Input manager: WASD movement, mouse aim + fire, keyboard weapon switching (1-4)
  $dir/js/collision.js - Collision detection: circle-circle, AABB, spatial hash grid for performance
  $dir/js/utils.js    - Math helpers: vector ops, random ranges, lerp, distance, angle

GAMEPLAY REQUIREMENTS:
- Top-down arena view on HTML5 Canvas (960x640 or responsive)
- WASD to move, mouse to aim, click/hold to fire
- Weapons: start with pistol, pick up others. Each weapon has unique fire rate, damage, pattern.
- 4 enemy types with distinct behaviors and visual designs
- Boss enemy every 5 waves: large, high HP, attack patterns, drops best loot
- Power-ups drop from killed enemies with weighted randomness
- Combo system: kills within 2 seconds increase combo multiplier (score x combo)
- Particle system for all visual feedback (at least 5 different particle types)
- Procedural sound effects via Web Audio API oscillators (no audio files needed)
- Game states: title screen, playing, paused (ESC), game over with stats
- Difficulty scaling: enemy count, speed, HP all increase per wave
- Score persisted to localStorage (high score table, top 5)
- Retro arcade aesthetic: dark background, neon colors, screen shake on explosions, CRT scanline CSS effect

Write ALL files listed above. Each file should be well-structured with classes and clear separation of concerns. This is a real game — make it fun and polished."

    log_run "Sending job to agent (this is a large project, expect 5-15 minutes)..."
    run_agent_job "test-$name" "$prompt" "$dir"

    echo ""
    log_run "Validating output..."
    local ok=true

    # Core files
    check_file_exists "$dir/index.html" "index.html exists" || ok=false
    check_file_min_size "$dir/index.html" 500 "index.html has content" || ok=false

    # CSS
    check_file_exists "$dir/css/style.css" "css/style.css exists" || ok=false

    # JS modules
    local js_files=("game" "player" "enemies" "weapons" "powerups" "waves" "particles" "hud" "audio" "input" "collision" "utils")
    local js_found=0
    for jsf in "${js_files[@]}"; do
        if [ -f "$dir/js/${jsf}.js" ]; then
            js_found=$((js_found + 1))
            log_ok "js/${jsf}.js exists"
        else
            log_fail "js/${jsf}.js missing"
            ok=false
        fi
    done
    log_info "$js_found/${#js_files[@]} JS modules found"

    # Content checks on key files
    if [ -f "$dir/js/game.js" ]; then
        check_file_min_size "$dir/js/game.js" 1000 "game.js has substantial code" || ok=false
        check_file_contains "$dir/js/game.js" "requestAnimationFrame\|gameLoop\|update\|render" "game.js has game loop" || ok=false
    fi
    if [ -f "$dir/js/player.js" ]; then
        check_file_contains "$dir/js/player.js" "WASD\|wasd\|KeyW\|KeyA\|KeyS\|KeyD\|move\|velocity" "player.js has WASD movement" || ok=false
    fi
    if [ -f "$dir/js/enemies.js" ]; then
        check_file_contains "$dir/js/enemies.js" "Grunt\|grunt\|Sniper\|sniper\|Tank\|tank\|Boss\|boss\|enemy\|Enemy" "enemies.js has enemy types" || ok=false
    fi
    if [ -f "$dir/js/weapons.js" ]; then
        check_file_contains "$dir/js/weapons.js" "pistol\|Pistol\|shotgun\|Shotgun\|laser\|Laser\|rocket\|Rocket\|weapon\|Weapon\|fire\|shoot" "weapons.js has weapon types" || ok=false
    fi
    if [ -f "$dir/js/particles.js" ]; then
        check_file_contains "$dir/js/particles.js" "particle\|Particle\|emit\|Emit\|explosion\|Explosion\|effect" "particles.js has particle system" || ok=false
    fi
    if [ -f "$dir/js/waves.js" ]; then
        check_file_contains "$dir/js/waves.js" "wave\|Wave\|spawn\|Spawn\|difficulty\|level" "waves.js has wave system" || ok=false
    fi
    if [ -f "$dir/js/audio.js" ]; then
        check_file_contains "$dir/js/audio.js" "AudioContext\|audioContext\|oscillator\|Oscillator\|sound\|Sound\|play" "audio.js has Web Audio" || ok=false
    fi

    # Total project size check
    if [ -d "$dir/js" ]; then
        local total_js_size
        total_js_size=$(du -sb "$dir/js/" 2>/dev/null | cut -f1)
        if [ "$total_js_size" -ge 10000 ]; then
            log_ok "JS codebase has substance (${total_js_size} bytes)"
        else
            log_fail "JS codebase too small (${total_js_size} bytes, expected >= 10KB)"
            ok=false
        fi
    fi

    if [ "$ok" = true ]; then record_result "$name" "PASS"; else record_result "$name" "FAIL"; fi
}

# -------------------------------------------------------------------------
#  Main
# -------------------------------------------------------------------------

banner
echo -e "  ${DIM}Sends coding jobs to the agent and validates the output files.${RST}"
echo ""

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
