#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Build Project
#
#  Generates a project from a text description, then iteratively improves it
#  in a loop: code → screenshot → vision review → fix → test → repeat.
#
#  Batches by model (coder stays loaded for code, vision loads once for review)
#  to avoid thrashing GPU memory.
#
#  Usage:
#    scripts/build-project.sh "Build a Tetris web game" [options]
#    ./iterate "Build a REST API for a bookstore" --hours 2
#
#  Options:
#    --name <name>       Project name (default: derived from description)
#    --hours <n>         Max hours to iterate (default: 4)
#    --dir <path>        Output directory (default: examples/<name>)
#    --no-vision         Skip vision model reviews
#    --vision-model <m>  Vision model to use (default: qwen3-vl:32b)
#
#  Examples:
#    ./iterate "Build a Tetris game with HTML5 canvas"
#    ./iterate "Create a REST API for a bookstore" --hours 2
#    ./iterate "Refactor tritium-coder test suite" --dir . --hours 1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
#  Parse arguments
# =============================================================================

DESCRIPTION=""
PROJECT_NAME=""
HOURS=4
OUTPUT_DIR=""
USE_VISION=true
VISION_MODEL="qwen3-vl:32b"

while [ $# -gt 0 ]; do
    case "$1" in
        --name)     PROJECT_NAME="$2"; shift 2 ;;
        --hours)    HOURS="$2"; shift 2 ;;
        --dir)      OUTPUT_DIR="$2"; shift 2 ;;
        --no-vision) USE_VISION=false; shift ;;
        --vision-model) VISION_MODEL="$2"; shift 2 ;;
        --help|-h)
            banner
            echo "  Usage: scripts/build-project.sh \"<description>\" [options]"
            echo ""
            echo "  Options:"
            echo "    --name <name>         Project name"
            echo "    --hours <n>           Max hours (default: 4)"
            echo "    --dir <path>          Output directory"
            echo "    --no-vision           Skip vision reviews"
            echo "    --vision-model <m>    Vision model (default: qwen3-vl:32b)"
            echo ""
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$DESCRIPTION" ]; then
                DESCRIPTION="$1"
            else
                DESCRIPTION="$DESCRIPTION $1"
            fi
            shift
            ;;
    esac
done

if [ -z "$DESCRIPTION" ]; then
    echo "Error: provide a project description" >&2
    echo "Usage: scripts/iterate.sh \"Build a Tetris game\" [--hours 4]" >&2
    exit 1
fi

# Derive project name from description if not set
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-30)
fi

# Default output dir
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${PROJECT_DIR}/examples/${PROJECT_NAME}"
fi

DURATION_SECS=$((HOURS * 3600))
START_TIME=$(date +%s)
CODER_MODEL="$OLLAMA_MODEL_NAME"
OLLAMA_URL="$(get_ollama_url)"
SESSION_ID="iterate-${PROJECT_NAME}-$(date +%s)"
LOG_FILE="$LOG_DIR/iterate-${PROJECT_NAME}.log"
CYCLE=0
VISION_FEEDBACK=""
CYCLE_HISTORY=""   # Running log of what was done each cycle (fed to agent for memory)

# =============================================================================
#  Helpers
# =============================================================================

log_to() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
elapsed_secs() { echo $(( $(date +%s) - START_TIME )); }
time_remaining() { echo $(( DURATION_SECS - $(elapsed_secs) )); }

# Append to cycle history (keeps last 10 entries to avoid prompt bloat)
record_cycle() {
    local entry="Cycle #${CYCLE} (${1}): ${2}"
    CYCLE_HISTORY="${CYCLE_HISTORY}
${entry}"
    # Trim to last 10 lines
    CYCLE_HISTORY=$(echo "$CYCLE_HISTORY" | tail -10)
}

# Build a context prefix shared by all prompts: CLAUDE.md + cycle history
prompt_context() {
    local ctx=""

    # Include CLAUDE.md if it exists in the output dir or its parent
    for candidate in "${OUTPUT_DIR}/CLAUDE.md" "${OUTPUT_DIR}/../CLAUDE.md"; do
        if [ -f "$candidate" ]; then
            ctx="IMPORTANT: Read ${candidate} first for project context.

"
            break
        fi
    done

    # Include cycle history so the agent remembers what it already did
    if [ -n "$CYCLE_HISTORY" ]; then
        ctx="${ctx}PREVIOUS ITERATIONS (what you already did — do NOT repeat, build on it):
${CYCLE_HISTORY}

"
    fi

    echo "$ctx"
}

agent_code() {
    local prompt="$1"
    local timeout="${2:-900}"
    # Use gateway mode (not --local) so the agent has full tool access:
    # file read/write, shell exec, etc. The gateway must be running.
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-tritium-local-dev}" \
    openclaw agent \
        --session-id "$SESSION_ID" \
        --message "$prompt" \
        --thinking medium \
        --timeout "$timeout" 2>/dev/null || echo ""
}

unload_model() {
    curl -s "$OLLAMA_URL/api/generate" \
        -d "{\"model\":\"$1\",\"keep_alive\":0}" > /dev/null 2>&1 || true
}

load_model() {
    curl -s "$OLLAMA_URL/api/generate" \
        -d "{\"model\":\"$1\",\"prompt\":\"hi\",\"keep_alive\":\"30m\"}" > /dev/null 2>&1 || true
}

take_screenshot() {
    local html_path="$1" output_path="$2" width="${3:-1280}" height="${4:-720}"
    for bin in google-chrome chromium-browser chromium chrome; do
        if command -v "$bin" &>/dev/null; then
            "$bin" --headless=new --disable-gpu --screenshot="$output_path" \
                --window-size="${width},${height}" --no-sandbox \
                "file://${html_path}" 2>/dev/null && return 0
        fi
    done
    python3 -c "
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b=p.chromium.launch(headless=True);pg=b.new_page(viewport={'width':${width},'height':${height}})
    pg.goto('file://${html_path}',wait_until='networkidle');pg.wait_for_timeout(2000)
    pg.screenshot(path='${output_path}');b.close()
" 2>/dev/null && return 0
    return 1
}

# Multi-resolution screenshot + vision review.
# Only called after polish/test phases when the agent thinks it's done something good.
# Takes screenshots at multiple resolutions and asks the vision model to be brutal.
VISION_RESOLUTIONS=(
    "1920 1080 desktop-1080p"
    "1280 720  desktop-720p"
    "768  1024 tablet-portrait"
    "375  812  mobile-iphone"
    "2560 1440 ultrawide"
)

run_vision_gate() {
    if [ "$USE_VISION" != true ]; then return; fi
    if [ "$(time_remaining)" -le 600 ]; then return; fi

    local html_file
    html_file=$(find "$OUTPUT_DIR" -name 'index.html' -maxdepth 1 | head -1)
    [ -z "$html_file" ] && return

    log_to "VISION GATE — multi-resolution review starting"

    # Unload coder to free GPU for vision model
    unload_model "$CODER_MODEL"
    sleep 2

    local ss_dir="/tmp/tritium-vision-gate-${PROJECT_NAME}"
    rm -rf "$ss_dir"
    mkdir -p "$ss_dir"
    local captured=0
    local max_screenshots=25  # per resolution, hard cap

    # --- Generate the interaction/screenshot script ---
    # This exercises all UI states: load, interact, pause, game over, etc.
    local interact_script="${ss_dir}/interact.py"
    cat > "$interact_script" << 'PYEOF'
import sys, os, time, json

html_path = sys.argv[1]
ss_dir = sys.argv[2]
width = int(sys.argv[3])
height = int(sys.argv[4])
label = sys.argv[5]
max_ss = int(sys.argv[6])

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("playwright not available", file=sys.stderr)
    sys.exit(1)

def ss(page, name):
    """Take a screenshot with a descriptive name."""
    global captured
    if captured >= max_ss:
        return
    path = os.path.join(ss_dir, f"{label}_{name}.png")
    page.screenshot(path=path)
    captured += 1
    print(f"  SCREENSHOT {label}/{name} ({width}x{height})")

captured = 0

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": width, "height": height})
    page.goto(f"file://{html_path}", wait_until="networkidle")
    time.sleep(1)

    # 1. Initial load state (title screen / menu)
    ss(page, "01_initial_load")

    # 2. Wait a moment for any animations
    time.sleep(2)
    ss(page, "02_after_animations")

    # 3. Try clicking common start buttons
    for selector in ["#start", "#play", "#btn-start", "#btn-play",
                     "button", ".start", ".play", ".btn-start",
                     "[data-action=start]", "a.btn"]:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                el.click()
                time.sleep(1)
                ss(page, "03_after_start_click")
                break
        except:
            pass

    # 4. Try pressing common start keys (Enter, Space)
    for key in ["Enter", " ", "Space"]:
        try:
            page.keyboard.press(key)
            time.sleep(0.5)
        except:
            pass
    time.sleep(1)
    ss(page, "04_gameplay_start")

    # 5. Simulate gameplay inputs for a few seconds
    import random
    game_keys = ["ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp",
                 "a", "d", "w", "s", " "]
    for i in range(20):
        try:
            key = random.choice(game_keys)
            page.keyboard.press(key)
            time.sleep(0.2)
        except:
            pass

    ss(page, "05_during_gameplay")
    time.sleep(2)
    ss(page, "06_gameplay_continued")

    # 6. More gameplay
    for i in range(30):
        try:
            page.keyboard.press(random.choice(game_keys))
            time.sleep(0.15)
        except:
            pass

    ss(page, "07_mid_game")

    # 7. Try pause (Escape or P)
    for key in ["Escape", "p", "P"]:
        try:
            page.keyboard.press(key)
            time.sleep(0.5)
        except:
            pass
    ss(page, "08_pause_attempt")

    # 8. Unpause
    for key in ["Escape", "p", "P", "Enter"]:
        try:
            page.keyboard.press(key)
            time.sleep(0.3)
        except:
            pass
    time.sleep(1)
    ss(page, "09_after_unpause")

    # 9. Try to trigger game over (mash keys, wait)
    for i in range(50):
        try:
            page.keyboard.press(random.choice(game_keys))
            time.sleep(0.1)
        except:
            pass
    time.sleep(3)
    ss(page, "10_late_game")

    # 10. Try clicking around the page for any interactive elements
    page_w, page_h = width, height
    click_points = [(page_w//2, page_h//2), (page_w//4, page_h//4),
                    (3*page_w//4, page_h//4), (page_w//2, 3*page_h//4)]
    for x, y in click_points:
        try:
            page.mouse.click(x, y)
            time.sleep(0.3)
        except:
            pass
    ss(page, "11_after_clicks")

    # 11. Check for any modals, overlays, settings panels
    for selector in [".modal", ".overlay", ".settings", "#settings",
                     ".menu", "#menu", ".dialog", "#game-over",
                     ".game-over", "#gameover"]:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                ss(page, f"12_ui_{selector.replace('#','').replace('.','')}")
                break
        except:
            pass

    # 12. Try to resize and see if layout adapts (only if not mobile)
    if width > 500:
        try:
            page.set_viewport_size({"width": width // 2, "height": height})
            time.sleep(1)
            ss(page, "13_half_width")
            page.set_viewport_size({"width": width, "height": height})
        except:
            pass

    # 13. Scroll check (if page is scrollable)
    try:
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        time.sleep(0.5)
        ss(page, "14_scrolled_bottom")
        page.evaluate("window.scrollTo(0, 0)")
    except:
        pass

    # 14. Console errors
    errors = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    time.sleep(1)

    # 15. Final state
    ss(page, "15_final_state")

    browser.close()

    # Write console errors to file for the vision prompt
    if errors:
        with open(os.path.join(ss_dir, f"{label}_console_errors.txt"), "w") as f:
            f.write("\n".join(errors[:20]))
        print(f"  CONSOLE ERRORS: {len(errors)} errors captured")

    print(f"  TOTAL: {captured} screenshots at {label} ({width}x{height})")
PYEOF

    # --- Capture at all resolutions ---
    for entry in "${VISION_RESOLUTIONS[@]}"; do
        read -r w h label <<< "$entry"
        log_to "SCREENSHOT capturing ${label} (${w}x${h}) — exercising all UI states"

        # Try playwright interaction script first (exercises UI states)
        if python3 "$interact_script" "$html_file" "$ss_dir" "$w" "$h" "$label" "$max_screenshots" 2>/dev/null; then
            local res_count
            res_count=$(find "$ss_dir" -name "${label}_*.png" 2>/dev/null | wc -l)
            log_to "SCREENSHOT ${label}: ${res_count} screenshots captured"
            captured=$((captured + res_count))
        else
            # Fallback: simple single screenshot
            if take_screenshot "$html_file" "${ss_dir}/${label}_01_initial_load.png" "$w" "$h"; then
                log_to "SCREENSHOT ${label}: 1 screenshot (simple fallback)"
                captured=$((captured + 1))
            else
                log_to "SCREENSHOT ${label}: FAILED"
            fi
        fi
    done

    rm -f "$interact_script"

    if [ "$captured" -eq 0 ]; then
        log_to "VISION GATE — no screenshots captured, skipping"
        rm -rf "$ss_dir"
        return
    fi

    log_to "VISION GATE — ${captured} total screenshots across all resolutions"

    # --- Load vision model once, review all screenshots ---
    load_model "$VISION_MODEL"

    local all_feedback=""
    local reviewed=0

    # Group screenshots by resolution and review each
    for entry in "${VISION_RESOLUTIONS[@]}"; do
        read -r w h label <<< "$entry"
        local screenshots
        screenshots=$(find "$ss_dir" -name "${label}_*.png" 2>/dev/null | sort)
        [ -z "$screenshots" ] && continue

        # Read console errors if captured
        local console_errors=""
        if [ -f "${ss_dir}/${label}_console_errors.txt" ]; then
            console_errors=$(cat "${ss_dir}/${label}_console_errors.txt")
        fi

        # Review each screenshot at this resolution
        while IFS= read -r ss_path; do
            local ss_name
            ss_name=$(basename "$ss_path" .png)

            log_to "VISION reviewing ${ss_name}"
            local fb
            local console_section=""
            [ -n "$console_errors" ] && console_section="

CONSOLE ERRORS DETECTED:
${console_errors}
These are JavaScript errors in the browser console. Every one is a bug."

            fb=$(vision_review "$ss_path" \
                "Screenshot: ${ss_name} at ${w}x${h} (${label}).
Project: ${DESCRIPTION}

You are a BRUTAL QA tester and design critic. Your job is to find EVERY flaw.

1. WHAT STATE IS THIS? (menu, gameplay, pause, game over, settings, broken?)
2. LAYOUT BUGS: Anything overflow, overlap, cut off, or misaligned?
3. TEXT: Can you read everything? Font size ok? Contrast ok?
4. VISUAL QUALITY (1-10, harsh): Does this look professional or amateur?
5. MISSING ELEMENTS: What should be on screen that isn't? (HUD, score, health, controls hint?)
6. RENDERING BUGS: Anything look glitched, torn, or incorrectly drawn?
7. RESPONSIVENESS: Does the layout work at ${w}x${h} or is it clearly wrong for this size?${console_section}

List EVERY problem. Be merciless. If you would be embarrassed to show this to a user, say so and say why.")

            if [ -n "$fb" ]; then
                all_feedback="${all_feedback}

--- ${ss_name} (${w}x${h}) ---
${fb}"
                reviewed=$((reviewed + 1))
            fi
        done <<< "$screenshots"
    done

    # Unload vision model
    unload_model "$VISION_MODEL"
    rm -rf "$ss_dir"
    sleep 2

    if [ -n "$all_feedback" ]; then
        VISION_FEEDBACK="MULTI-RESOLUTION VISION REVIEW (${captured} screenshots across ${#VISION_RESOLUTIONS[@]} viewports, ${reviewed} reviewed):
${all_feedback}

EVERY issue above must be fixed. The project must look professional at ALL resolutions and in ALL states (menu, gameplay, pause, game over). Console errors are BUGS that must be fixed."
        log_to "VISION GATE complete — ${reviewed} reviews, total feedback_len=${#VISION_FEEDBACK}"
    else
        VISION_FEEDBACK=""
        log_to "VISION GATE complete — no feedback received"
    fi
}

vision_review() {
    local image_path="$1" prompt="$2"
    [ ! -f "$image_path" ] && return
    local b64
    b64=$(base64 -w0 "$image_path" 2>/dev/null || base64 "$image_path" 2>/dev/null)
    local escaped_prompt
    escaped_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt")
    curl -s "$OLLAMA_URL/api/chat" --max-time 180 \
        -d "{\"model\":\"${VISION_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":${escaped_prompt},\"images\":[\"${b64}\"]}],\"stream\":false}" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',{}).get('content',''))" 2>/dev/null || echo ""
}

# =============================================================================
#  Prompt templates
# =============================================================================

prompt_generate() {
    local ctx
    ctx=$(prompt_context)
    cat << PROMPT
${ctx}Build this project from scratch:

${DESCRIPTION}

Write all files to: ${OUTPUT_DIR}

Requirements:
- Create a complete, working implementation
- Use HTML5/CSS3/JavaScript (no external dependencies, no CDN links)
- Make it visually polished from the start (dark theme, modern design, animations)
- Include all game logic, rendering, input handling, and scoring
- Must work by opening index.html in a browser — fully self-contained
- Add sound effects using Web Audio API (synthesized, no audio files)

Write ALL files now. Make sure the project works immediately.
PROMPT
}

prompt_fix() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION MODEL REVIEW (from screenshot of current state):
${VISION_FEEDBACK}

Fix every issue the vision model identified."

    cat << PROMPT
${ctx}You are iterating on a project in ${OUTPUT_DIR}.

Read ALL source files in ${OUTPUT_DIR} to understand the current state.

YOUR JOB: Find and fix everything that's broken.

1. Read every file carefully
2. Trace through the logic — find bugs, null references, broken state, render issues
3. Check all user input handling (keyboard, mouse, touch)
4. Check game state transitions (start → play → pause → game over → restart)
5. Check for JavaScript errors that would show in the console
6. FIX every bug you find — don't just list them

Write fixes directly to the files in ${OUTPUT_DIR}.${vision_section}

List every bug you found and how you fixed it.
PROMPT
}

prompt_improve() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION MODEL REVIEW (from screenshot):
${VISION_FEEDBACK}

Address the visual feedback above."

    cat << PROMPT
${ctx}You are iterating on a project in ${OUTPUT_DIR}.

Read ALL source files. The project should already work. Now improve it:

1. Add visual polish: particle effects, screen shake, smooth animations, glows
2. Add procedural sound effects via Web Audio API (no external audio files)
3. Add a HUD: score, high score, lives/level with animated transitions
4. Add difficulty progression — the experience should get harder over time
5. Add a proper start screen with title, instructions, and "Press Start"
6. Add a game over screen with stats, high score, and "Play Again"
7. Store high scores in localStorage
8. Make controls feel responsive and satisfying

Write all changes to ${OUTPUT_DIR}.${vision_section}

List every improvement you made.
PROMPT
}

prompt_test() {
    local ctx
    ctx=$(prompt_context)
    cat << PROMPT
${ctx}You are testing a project in ${OUTPUT_DIR}.

Read ALL source files. Create or update ${OUTPUT_DIR}/test.html.

IMPORTANT: Use the shared test harness at ${PROJECT_DIR}/lib/test-harness.js.
Read that file first to understand the API (TritiumTest class).

Your test.html should:
1. Include: <script src="../../lib/test-harness.js"></script>
2. Include the game/app scripts
3. Create tests:
   const t = new TritiumTest('${PROJECT_NAME}');
   t.test('loads without error', function() { ... });
   t.test('canvas exists', function() { t.assertExists('canvas'); });
   t.test('score starts at 0', function() { t.assertEqual(game.score, 0); });
   t.run();

Test:
- Initialization (no crash on load)
- State management (all states reachable)
- Scoring/data logic
- Input handling setup
- Rendering pipeline (canvas or DOM elements exist)

Also fix any bugs you discover while writing the tests.

Write all files to ${OUTPUT_DIR}.

List every test and what it verifies.
PROMPT
}

prompt_features() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION MODEL FEEDBACK:
${VISION_FEEDBACK}"

    cat << PROMPT
${ctx}You are adding features to a project in ${OUTPUT_DIR}.

Read ALL source files. The project should be stable. Now add NEW FEATURES:

Think about what would make this project significantly better. Add 2-3 meaningful features:
- New gameplay mechanics, power-ups, enemy types, or modes
- Visual effects: particle trails, explosions, lightning, parallax backgrounds
- Background music with Web Audio API (procedurally generated)
- Mobile/touch support
- Accessibility improvements
- Performance optimizations

Write all changes to ${OUTPUT_DIR}.${vision_section}

Describe each new feature and why it improves the project.
PROMPT
}

prompt_polish() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION MODEL REVIEW:
${VISION_FEEDBACK}"

    cat << PROMPT
${ctx}Final polish pass on the project in ${OUTPUT_DIR}.

Read ALL source files. This is a quality review:

1. Is the code well-structured? Refactor if it's messy.
2. Are there any remaining bugs? Fix them.
3. Does the visual design look professional? Improve colors, spacing, fonts.
4. Are transitions smooth? Add CSS/canvas transitions where missing.
5. Does the README.md exist and explain how to play/use?
6. Is the game/app actually fun/useful? What's the weakest part?
7. Add any missing finishing touches.

Write all changes to ${OUTPUT_DIR}.${vision_section}

Rate the project 1-10 and explain what would bring it to a 10.
PROMPT
}

prompt_runtests() {
    local ctx
    ctx=$(prompt_context)

    # Detect what kind of tests exist
    local test_info=""
    if [ -f "${OUTPUT_DIR}/test.html" ]; then
        test_info="A test.html file exists — it uses the TritiumTest harness."
    fi
    if [ -f "${OUTPUT_DIR}/package.json" ]; then
        test_info="${test_info} A package.json exists — check for test scripts."
    fi
    for f in "${OUTPUT_DIR}"/*test*.py "${OUTPUT_DIR}"/test_*.py "${OUTPUT_DIR}"/tests/*.py; do
        if [ -f "$f" ] 2>/dev/null; then
            test_info="${test_info} Python test files found."
            break
        fi
    done

    cat << PROMPT
${ctx}You are running tests for a project in ${OUTPUT_DIR}.

${test_info}

YOUR JOB: Actually EXECUTE the tests and fix what's broken.

1. If test.html exists, open it with a headless check or read it to understand what's tested
2. If Python tests exist, run them: cd ${OUTPUT_DIR} && python3 -m pytest or python3 test_*.py
3. If package.json has test scripts, run: cd ${OUTPUT_DIR} && npm test
4. If no tests exist yet, CREATE them first (use ${PROJECT_DIR}/lib/test-harness.js for web projects)
5. Run: python3 -c "import py_compile; py_compile.compile('${OUTPUT_DIR}/FILE', doraise=True)" for Python files
6. For JS/HTML: check for syntax errors by reading the code carefully

For ANY test failure:
- Read the error output
- Find the root cause in the source code
- FIX the bug
- Re-run to verify the fix works

Write all fixes to ${OUTPUT_DIR}.

Report: which tests passed, which failed, what you fixed.
PROMPT
}

# Git checkpoint: commit working state after successful cycles
git_checkpoint() {
    local msg="$1"

    # Only checkpoint if output dir is inside a git repo
    if ! git -C "$OUTPUT_DIR" rev-parse --git-dir &>/dev/null; then
        return
    fi

    local changes
    changes=$(git -C "$OUTPUT_DIR" status --porcelain 2>/dev/null | wc -l)
    if [ "$changes" -eq 0 ]; then
        return
    fi

    git -C "$OUTPUT_DIR" add -A 2>/dev/null || return
    git -C "$OUTPUT_DIR" commit -m "[auto] ${msg}" --no-verify 2>/dev/null || return
    log_to "GIT    checkpoint: ${msg} (${changes} files)"
}

# =============================================================================
#  Preflight
# =============================================================================

banner
section "Iterate: ${PROJECT_NAME}"

echo "  Description: ${DESCRIPTION}"
echo "  Output:      ${OUTPUT_DIR}"
echo "  Duration:    ${HOURS} hours"
echo "  Coder:       ${CODER_MODEL}"
echo "  Vision:      ${VISION_MODEL} ($([ "$USE_VISION" = true ] && echo "enabled" || echo "disabled"))"
echo "  Session:     ${SESSION_ID}"
echo ""

log_to "START  project=${PROJECT_NAME} hours=${HOURS} session=${SESSION_ID}"
log_to "       description=${DESCRIPTION}"

ensure_ollama  || exit 1
ensure_model   || exit 1
ensure_gateway || { log_fail "Gateway required for build-project (agent needs file tools)"; exit 1; }

# Check vision capability
CAN_SCREENSHOT=false
if [ "$USE_VISION" = true ]; then
    if ! ollama_has_model "$VISION_MODEL"; then
        log_warn "Vision model '${VISION_MODEL}' not available — skipping visual reviews"
        USE_VISION=false
    fi
    for bin in google-chrome chromium-browser chromium chrome; do
        command -v "$bin" &>/dev/null && CAN_SCREENSHOT=true && break
    done
    if [ "$CAN_SCREENSHOT" = false ]; then
        python3 -c "from playwright.sync_api import sync_playwright" 2>/dev/null && CAN_SCREENSHOT=true
    fi
    if [ "$CAN_SCREENSHOT" = false ]; then
        log_warn "No headless browser — screenshots disabled"
        USE_VISION=false
    fi
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# =============================================================================
#  Phase 0: Generate initial code (if directory is empty)
# =============================================================================

file_count=$(find "$OUTPUT_DIR" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.py' \) 2>/dev/null | wc -l)

if [ "$file_count" -eq 0 ]; then
    log_to "GENERATE initial code (empty directory)"
    echo ""
    echo "=== Generating initial project ==="
    echo ""

    load_model "$CODER_MODEL"
    response=$(agent_code "$(prompt_generate)" 900)
    log_to "GENERATE response_len=${#response}"

    file_count=$(find "$OUTPUT_DIR" -type f 2>/dev/null | wc -l)
    log_to "GENERATE created ${file_count} files"

    if [ "$file_count" -eq 0 ]; then
        log_to "GENERATE FAILED — no files created"
        echo "ERROR: Agent failed to generate initial code. Check ${LOG_FILE}"
        exit 1
    fi
fi

# =============================================================================
#  Main loop: fix → improve → test → features → polish
#  Vision gate runs AFTER test and polish phases (when the agent thinks it's good)
# =============================================================================

# Phases rotate: fix → improve → runtests → features → polish → test (write tests)
# "runtests" actually executes tests and fixes failures
# "test" writes/updates test files
# Vision gate fires after polish and runtests (agent thinks it's in good shape)
PHASES=("fix" "improve" "runtests" "features" "polish" "test")

while [ "$(time_remaining)" -gt 300 ]; do
    CYCLE=$((CYCLE + 1))
    remaining=$(time_remaining)
    phase_idx=$(( (CYCLE - 1) % ${#PHASES[@]} ))
    phase="${PHASES[$phase_idx]}"

    echo ""
    log_to "================================================================"
    log_to "CYCLE  #${CYCLE}  phase=${phase}  elapsed=$(($(elapsed_secs) / 60))m  remaining=$((remaining / 60))m"
    log_to "================================================================"

    # ----- CODE PASS (coder model stays loaded) -----
    load_model "$CODER_MODEL"

    local_prompt=""
    case "$phase" in
        fix)      local_prompt=$(prompt_fix) ;;
        improve)  local_prompt=$(prompt_improve) ;;
        test)     local_prompt=$(prompt_test) ;;
        runtests) local_prompt=$(prompt_runtests) ;;
        features) local_prompt=$(prompt_features) ;;
        polish)   local_prompt=$(prompt_polish) ;;
    esac

    iter_timeout=900
    remaining=$(time_remaining)
    [ "$remaining" -lt "$iter_timeout" ] && iter_timeout=$remaining

    log_to "CODE   phase=${phase} timeout=${iter_timeout}"
    response=$(agent_code "$local_prompt" "$iter_timeout")

    if [ -n "$response" ]; then
        log_to "CODE   response_len=${#response}"
        # Extract summary for cycle history
        local summary
        summary=$(echo "$response" | python3 -c "
import sys,json
try:
    data = json.load(sys.stdin)
    text = data.get('content','') or data.get('result','') or str(data)
    print(text[:200])
except:
    text = sys.stdin.read()
    print(text[:200])
" 2>/dev/null || echo "$response" | head -c 200)
        echo "$summary"
        echo ""
        record_cycle "$phase" "$summary"
    else
        log_to "CODE   response=EMPTY (may have timed out)"
        record_cycle "$phase" "No response (timeout or error)"
    fi

    # ----- GIT CHECKPOINT (after improve, features, polish — constructive phases) -----
    if [ "$phase" = "improve" ] || [ "$phase" = "features" ] || [ "$phase" = "polish" ]; then
        git_checkpoint "cycle-${CYCLE}-${phase}"
    fi

    # ----- VISION GATE (only after runtests or polish — when the agent thinks it's good) -----
    if [ "$phase" = "runtests" ] || [ "$phase" = "polish" ]; then
        log_to "VISION GATE triggered after ${phase} phase"
        run_vision_gate
        # If vision produced feedback, run an immediate fix pass to address it
        if [ -n "$VISION_FEEDBACK" ]; then
            log_to "VISION FIX — addressing vision gate feedback"
            load_model "$CODER_MODEL"
            local_prompt=$(prompt_fix)
            iter_timeout=900
            remaining=$(time_remaining)
            [ "$remaining" -lt "$iter_timeout" ] && iter_timeout=$remaining
            if [ "$iter_timeout" -gt 60 ]; then
                response=$(agent_code "$local_prompt" "$iter_timeout")
                log_to "VISION FIX response_len=${#response}"
                record_cycle "vision-fix" "Fixed issues from vision review"
                git_checkpoint "cycle-${CYCLE}-vision-fix"
            fi
            # Clear vision feedback after it's been addressed
            VISION_FEEDBACK=""
        fi
    fi

    # Brief pause
    sleep 3
done

# =============================================================================
#  Summary
# =============================================================================

TOTAL_TIME=$(elapsed_secs)
log_to "DONE   cycles=${CYCLE} total_time=${TOTAL_TIME}s"

# Final git checkpoint
git_checkpoint "final — ${CYCLE} cycles in $((TOTAL_TIME / 60))m"

echo ""
echo "=========================================="
echo "  Iteration complete: ${PROJECT_NAME}"
echo "  Cycles:    ${CYCLE}"
echo "  Duration:  $((TOTAL_TIME / 60)) minutes"
echo "  Output:    ${OUTPUT_DIR}"
echo "=========================================="
echo ""
echo "  Files:"
find "$OUTPUT_DIR" -type f | sort | while read -r f; do
    size=$(wc -c < "$f")
    rel="${f#${OUTPUT_DIR}/}"
    echo "    ${rel}  (${size} bytes)"
done
echo ""
echo "  View: python3 -m http.server 8080 -d ${OUTPUT_DIR}"
echo "  Logs: ${LOG_FILE}"
echo ""
