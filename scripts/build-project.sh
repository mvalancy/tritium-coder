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
        --resume)
            # Shorthand: --resume <name> is equivalent to --dir examples/<name>
            OUTPUT_DIR="${PROJECT_DIR}/examples/${2}"
            PROJECT_NAME="$2"
            shift 2
            ;;
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
            echo "    --resume <name>       Resume an existing project in examples/<name>"
            echo "    --no-vision           Skip vision reviews"
            echo "    --vision-model <m>    Vision model (default: qwen3-vl:32b)"
            echo ""
            echo "  Examples:"
            echo "    ./iterate \"Build a Tetris game\"                        # New project"
            echo "    ./iterate \"Build a Tetris game\" --hours 2              # 2 hour budget"
            echo "    ./iterate \"Add multiplayer\" --resume tetris            # Resume with new goal"
            echo "    ./iterate \"Fix the pause menu\" --dir examples/tetris   # Resume with --dir"
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

# Health check state — persists across cycles
HEALTH_STATUS=""           # Last health check result (PASS/WARN/FAIL)
HEALTH_DETAILS=""          # Human-readable details
HEALTH_JS_ERRORS=0         # Count of JS console errors
HEALTH_RENDERS=false       # Did the page render visible content?
HEALTH_LOADS=false         # Did the page load at all?
HEALTH_INTERACTIVE=false   # Did interactions produce state changes?
HEALTH_FILE_SIZES=""       # "file:lines" pairs for large files
LAST_HEALTH_CYCLE=0        # Last cycle we ran health check
CONSECUTIVE_FAILS=0        # How many health checks failed in a row
PHASE_SCORES=""            # Rolling phase confidence scores

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

# Record a phase confidence score (agent self-rating or computed)
record_score() {
    local phase="$1" score="$2"
    PHASE_SCORES="${PHASE_SCORES}
${phase}:${score}"
    PHASE_SCORES=$(echo "$PHASE_SCORES" | tail -20)
}

# Maturity tier: early (cycles 1-3), mid (4-10), late (11+)
# Changes the tone and focus of prompts
maturity_tier() {
    if [ "$CYCLE" -le 3 ]; then
        echo "early"
    elif [ "$CYCLE" -le 10 ]; then
        echo "mid"
    else
        echo "late"
    fi
}

maturity_guidance() {
    case "$(maturity_tier)" in
        early)
            echo "MATURITY: EARLY — Focus on getting it working. Don't over-polish yet. Make sure the core works."
            ;;
        mid)
            echo "MATURITY: MID — The core should work. Focus on quality, polish, and robustness."
            ;;
        late)
            echo "MATURITY: LATE — The project should be solid. Focus on edge cases, performance, and bulletproofing."
            ;;
    esac
}

# Measure file sizes and flag large ones
measure_files() {
    HEALTH_FILE_SIZES=""
    local large_files=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local lines
        lines=$(wc -l < "$f" 2>/dev/null || echo 0)
        local rel="${f#${OUTPUT_DIR}/}"
        if [ "$lines" -gt 800 ]; then
            large_files="${large_files}
  ${rel}: ${lines} lines"
        fi
    done < <(find "$OUTPUT_DIR" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.py' \) -not -path '*/screenshots/*' -not -path '*/docs/*' 2>/dev/null)
    HEALTH_FILE_SIZES="$large_files"
}

# =============================================================================
#  Health Check — "Does this app work? How do we know?"
#
#  Loads the app in playwright, checks:
#  1. Does it load without crashing?
#  2. Are there JS console errors?
#  3. Does it render visible content (not blank)?
#  4. Do interactions produce state changes?
#  5. Does it survive 10 seconds without crashing?
#
#  Produces: HEALTH_STATUS (PASS/WARN/FAIL), HEALTH_DETAILS (human readable)
# =============================================================================

run_health_check() {
    local html_file
    html_file=$(find "$OUTPUT_DIR" -name 'index.html' -maxdepth 1 | head -1)

    # Non-web projects: check for syntax errors in Python/JS files
    if [ -z "$html_file" ]; then
        run_headless_health_check
        return
    fi

    log_to "HEALTH checking: does this app actually work?"

    local hc_dir="/tmp/tritium-health-${PROJECT_NAME}"
    rm -rf "$hc_dir"
    mkdir -p "$hc_dir"

    # Write the health check script
    cat > "${hc_dir}/check.py" << 'HCEOF'
import sys, os, time, json

html_path = sys.argv[1]
result_path = sys.argv[2]

result = {
    "loads": False,
    "renders": False,
    "interactive": False,
    "js_errors": [],
    "crash": None,
    "visible_elements": 0,
    "canvas_pixels": 0,
    "state_changes": 0,
    "survival_secs": 0,
}

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    result["crash"] = "playwright not available"
    with open(result_path, "w") as f:
        json.dump(result, f)
    sys.exit(0)

try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1280, "height": 720})

        # Capture ALL console errors
        errors = []
        page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)

        # Capture page crashes
        page.on("pageerror", lambda err: errors.append(f"PAGE CRASH: {err}"))

        # 1. LOAD TEST — does it load at all?
        try:
            page.goto(f"file://{html_path}", wait_until="networkidle", timeout=15000)
            result["loads"] = True
        except Exception as e:
            result["crash"] = f"Failed to load: {e}"
            result["js_errors"] = errors
            with open(result_path, "w") as f:
                json.dump(result, f)
            browser.close()
            sys.exit(0)

        time.sleep(2)

        # 2. RENDER TEST — is there visible content?
        try:
            # Check for visible elements
            visible = page.evaluate("""() => {
                const els = document.querySelectorAll('canvas, img, div, span, p, h1, h2, h3, button, a, svg');
                let count = 0;
                els.forEach(el => {
                    const rect = el.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0) count++;
                });
                return count;
            }""")
            result["visible_elements"] = visible
            result["renders"] = visible > 0

            # Check canvas content (non-blank pixels)
            canvas_check = page.evaluate("""() => {
                const c = document.querySelector('canvas');
                if (!c) return 0;
                try {
                    const ctx = c.getContext('2d');
                    if (!ctx) return -1;  // might be webgl
                    const data = ctx.getImageData(0, 0, c.width, c.height).data;
                    let nonBlank = 0;
                    for (let i = 0; i < data.length; i += 4) {
                        if (data[i] > 0 || data[i+1] > 0 || data[i+2] > 0) nonBlank++;
                    }
                    return nonBlank;
                } catch(e) {
                    return -1;  // webgl or tainted
                }
            }""")
            result["canvas_pixels"] = canvas_check
            if canvas_check > 100:
                result["renders"] = True
            elif canvas_check == -1:
                result["renders"] = True  # WebGL — assume it's rendering

        except Exception as e:
            errors.append(f"Render check error: {e}")

        # 3. INTERACTION TEST — do inputs change state?
        try:
            # Snapshot DOM state before interactions
            before_state = page.evaluate("""() => {
                const c = document.querySelector('canvas');
                const texts = Array.from(document.querySelectorAll('*'))
                    .map(e => e.textContent).join('').slice(0, 500);
                return { textLen: texts.length, bodyHTML: document.body.innerHTML.length };
            }""")

            # Try starting the game / interacting
            for key in ["Enter", " "]:
                page.keyboard.press(key)
                time.sleep(0.3)

            import random
            for _ in range(15):
                page.keyboard.press(random.choice(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", " "]))
                time.sleep(0.15)

            time.sleep(1)

            # Snapshot after
            after_state = page.evaluate("""() => {
                const texts = Array.from(document.querySelectorAll('*'))
                    .map(e => e.textContent).join('').slice(0, 500);
                return { textLen: texts.length, bodyHTML: document.body.innerHTML.length };
            }""")

            changes = 0
            if before_state["textLen"] != after_state["textLen"]:
                changes += 1
            if before_state["bodyHTML"] != after_state["bodyHTML"]:
                changes += 1

            result["state_changes"] = changes
            result["interactive"] = changes > 0

        except Exception as e:
            errors.append(f"Interaction test error: {e}")

        # 4. SURVIVAL TEST — does it crash after 10 seconds?
        try:
            start = time.time()
            for sec in range(10):
                time.sleep(1)
                # Check if page is still alive
                page.evaluate("1+1")
            result["survival_secs"] = int(time.time() - start)
        except Exception as e:
            result["survival_secs"] = int(time.time() - start)
            errors.append(f"Crashed after {result['survival_secs']}s: {e}")

        result["js_errors"] = errors[:30]
        browser.close()

except Exception as e:
    result["crash"] = str(e)

with open(result_path, "w") as f:
    json.dump(result, f, indent=2)
HCEOF

    local result_file="${hc_dir}/result.json"

    if ! python3 "${hc_dir}/check.py" "$html_file" "$result_file" 2>/dev/null; then
        HEALTH_STATUS="FAIL"
        HEALTH_DETAILS="Health check script crashed"
        HEALTH_LOADS=false
        HEALTH_RENDERS=false
        HEALTH_INTERACTIVE=false
        HEALTH_JS_ERRORS=0
        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
        log_to "HEALTH FAIL — check script crashed"
        rm -rf "$hc_dir"
        return
    fi

    if [ ! -f "$result_file" ]; then
        HEALTH_STATUS="FAIL"
        HEALTH_DETAILS="No result produced"
        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
        log_to "HEALTH FAIL — no result file"
        rm -rf "$hc_dir"
        return
    fi

    # Parse results
    local loads renders interactive js_error_count survival crash canvas_pixels
    loads=$(python3 -c "import json; print(json.load(open('$result_file'))['loads'])" 2>/dev/null || echo "False")
    renders=$(python3 -c "import json; print(json.load(open('$result_file'))['renders'])" 2>/dev/null || echo "False")
    interactive=$(python3 -c "import json; print(json.load(open('$result_file'))['interactive'])" 2>/dev/null || echo "False")
    js_error_count=$(python3 -c "import json; print(len(json.load(open('$result_file'))['js_errors']))" 2>/dev/null || echo "0")
    survival=$(python3 -c "import json; print(json.load(open('$result_file'))['survival_secs'])" 2>/dev/null || echo "0")
    crash=$(python3 -c "import json; r=json.load(open('$result_file')); print(r.get('crash','') or '')" 2>/dev/null || echo "")
    canvas_pixels=$(python3 -c "import json; print(json.load(open('$result_file'))['canvas_pixels'])" 2>/dev/null || echo "0")

    HEALTH_LOADS=false; [ "$loads" = "True" ] && HEALTH_LOADS=true
    HEALTH_RENDERS=false; [ "$renders" = "True" ] && HEALTH_RENDERS=true
    HEALTH_INTERACTIVE=false; [ "$interactive" = "True" ] && HEALTH_INTERACTIVE=true
    HEALTH_JS_ERRORS=$js_error_count

    # Read JS error details for prompts
    local js_error_text=""
    if [ "$js_error_count" -gt 0 ]; then
        js_error_text=$(python3 -c "
import json
errors = json.load(open('$result_file'))['js_errors']
for e in errors[:10]:
    print(f'  - {e}')
" 2>/dev/null || echo "")
    fi

    # Determine overall status
    local details=""
    if [ "$HEALTH_LOADS" != true ]; then
        HEALTH_STATUS="FAIL"
        details="App FAILED to load"
        [ -n "$crash" ] && details="${details}: ${crash}"
    elif [ "$HEALTH_RENDERS" != true ]; then
        HEALTH_STATUS="FAIL"
        details="App loads but renders BLANK (no visible content, canvas pixels: ${canvas_pixels})"
    elif [ "$js_error_count" -gt 5 ]; then
        HEALTH_STATUS="FAIL"
        details="App renders but has ${js_error_count} JS errors — critically broken"
    elif [ "$survival" -lt 5 ]; then
        HEALTH_STATUS="FAIL"
        details="App crashed within ${survival} seconds"
    elif [ "$js_error_count" -gt 0 ]; then
        HEALTH_STATUS="WARN"
        details="App works but has ${js_error_count} JS error(s)"
    elif [ "$HEALTH_INTERACTIVE" != true ]; then
        HEALTH_STATUS="WARN"
        details="App loads and renders but may not respond to input"
    else
        HEALTH_STATUS="PASS"
        details="App loads, renders, responds to input, survived ${survival}s"
        CONSECUTIVE_FAILS=0
    fi

    if [ -n "$js_error_text" ]; then
        details="${details}
JS errors:
${js_error_text}"
    fi

    HEALTH_DETAILS="$details"
    LAST_HEALTH_CYCLE=$CYCLE

    if [ "$HEALTH_STATUS" = "FAIL" ]; then
        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
    elif [ "$HEALTH_STATUS" = "PASS" ]; then
        CONSECUTIVE_FAILS=0
    fi

    # Also measure file sizes while we're at it
    measure_files

    log_to "HEALTH ${HEALTH_STATUS} — ${details}"
    rm -rf "$hc_dir"
}

# Health check for non-web projects (Python, etc.)
run_headless_health_check() {
    log_to "HEALTH checking non-web project (syntax/import checks)"
    local errors=""
    local error_count=0

    # Check Python files for syntax errors
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local result
        result=$(python3 -c "import py_compile; py_compile.compile('$f', doraise=True)" 2>&1) || {
            errors="${errors}
  - $(basename "$f"): ${result}"
            error_count=$((error_count + 1))
        }
    done < <(find "$OUTPUT_DIR" -name '*.py' -not -name '__pycache__' 2>/dev/null)

    # Check JS files for basic syntax (Node if available)
    if command -v node &>/dev/null; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local result
            result=$(node --check "$f" 2>&1) || {
                errors="${errors}
  - $(basename "$f"): ${result}"
                error_count=$((error_count + 1))
            }
        done < <(find "$OUTPUT_DIR" -name '*.js' -not -path '*/node_modules/*' 2>/dev/null)
    fi

    if [ "$error_count" -eq 0 ]; then
        HEALTH_STATUS="PASS"
        HEALTH_DETAILS="All files pass syntax checks"
        HEALTH_LOADS=true
        CONSECUTIVE_FAILS=0
    else
        HEALTH_STATUS="FAIL"
        HEALTH_DETAILS="Syntax errors found:${errors}"
        HEALTH_LOADS=false
        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
    fi

    HEALTH_JS_ERRORS=$error_count
    LAST_HEALTH_CYCLE=$CYCLE
    measure_files
    log_to "HEALTH ${HEALTH_STATUS} — ${HEALTH_DETAILS}"
}

# =============================================================================
#  Dynamic Phase Selection
#
#  Instead of fixed rotation, look at signals and pick what matters most:
#  - App broken (FAIL)?           → fix
#  - App has warnings?            → fix
#  - Files too big?               → refactor
#  - Tests not written yet?       → test
#  - Tests exist but not run?     → runtests
#  - App works, early maturity?   → features
#  - App works, mid maturity?     → improve/polish
#  - App works, late maturity?    → consolidate/docs
# =============================================================================

select_phase() {
    # If health check hasn't run yet (first cycle), start with health
    if [ "$LAST_HEALTH_CYCLE" -eq 0 ] && [ "$CYCLE" -gt 1 ]; then
        echo "fix"
        return
    fi

    # CRITICAL: If app is broken, always fix first
    if [ "$HEALTH_STATUS" = "FAIL" ]; then
        # If we've failed 3+ times in a row, try a different approach
        if [ "$CONSECUTIVE_FAILS" -ge 3 ]; then
            log_to "PHASE  3 consecutive failures — trying runtests to diagnose"
            echo "runtests"
        else
            echo "fix"
        fi
        return
    fi

    # WARNING: App has issues but isn't broken
    if [ "$HEALTH_STATUS" = "WARN" ]; then
        echo "fix"
        return
    fi

    # FILES TOO BIG: Refactor before adding more
    if [ -n "$HEALTH_FILE_SIZES" ]; then
        local biggest
        biggest=$(echo "$HEALTH_FILE_SIZES" | head -1 | grep -oP '\d+ lines' | grep -oP '\d+')
        if [ -n "$biggest" ] && [ "$biggest" -gt 1500 ]; then
            echo "refactor"
            return
        fi
    fi

    # MATURITY-BASED SELECTION
    local tier
    tier=$(maturity_tier)

    case "$tier" in
        early)
            # Early: cycle through fix → improve → test → features
            local early_phases=("improve" "test" "runtests" "features")
            local idx=$(( (CYCLE - 1) % ${#early_phases[@]} ))
            echo "${early_phases[$idx]}"
            ;;
        mid)
            # Mid: more polish, features, docs
            local mid_phases=("improve" "runtests" "features" "polish" "test" "docs")
            local idx=$(( (CYCLE - 1) % ${#mid_phases[@]} ))
            echo "${mid_phases[$idx]}"
            ;;
        late)
            # Late: consolidation, docs, polish, edge cases
            local late_phases=("consolidate" "runtests" "polish" "docs" "refactor" "test")
            local idx=$(( (CYCLE - 1) % ${#late_phases[@]} ))
            echo "${late_phases[$idx]}"
            ;;
    esac
}

# Build a context prefix shared by all prompts: CLAUDE.md + cycle history + health + maturity
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

    # Project directive — what the user asked for (drives every phase, especially resume)
    ctx="${ctx}PROJECT GOAL: ${DESCRIPTION}

PHILOSOPHY: Take your time. Quality over speed. Trust nothing — verify everything from the USER's perspective, not just code review. Ask: 'would a real person have a good experience?'

$(maturity_guidance)

"

    # Health status (the most important signal)
    if [ -n "$HEALTH_STATUS" ]; then
        ctx="${ctx}HEALTH STATUS: ${HEALTH_STATUS}
${HEALTH_DETAILS}

"
    fi

    # Large file warnings
    if [ -n "$HEALTH_FILE_SIZES" ]; then
        ctx="${ctx}LARGE FILES (consider splitting):${HEALTH_FILE_SIZES}

"
    fi

    # Include cycle history so the agent remembers what it already did
    if [ -n "$CYCLE_HISTORY" ]; then
        ctx="${ctx}PREVIOUS ITERATIONS (do NOT repeat — build on this):
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

    # --- Persist best screenshots to project's screenshots/ folder ---
    local proj_ss_dir="${OUTPUT_DIR}/screenshots"
    mkdir -p "$proj_ss_dir"
    # Keep one representative screenshot per resolution (the initial load and gameplay)
    for entry in "${VISION_RESOLUTIONS[@]}"; do
        read -r w h label <<< "$entry"
        for pick in "01_initial_load" "05_during_gameplay" "08_pause_attempt" "15_final_state"; do
            local src="${ss_dir}/${label}_${pick}.png"
            if [ -f "$src" ]; then
                cp "$src" "${proj_ss_dir}/${label}_${pick}.png"
            fi
        done
    done
    local saved_count
    saved_count=$(find "$proj_ss_dir" -name '*.png' 2>/dev/null | wc -l)
    log_to "SCREENSHOTS saved ${saved_count} to ${proj_ss_dir}"

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

Take your time. Quality matters more than speed.

Requirements:
- Create a complete, working implementation
- Use HTML5/CSS3/JavaScript (no external dependencies, no CDN links)
- Make it visually polished (dark theme, modern design, animations)
- Must work by opening index.html in a browser — fully self-contained
- Separate concerns: game logic, rendering, and input in different files or clear sections
- Create a README.md explaining what it is, how to run it, controls, and features
- Create a docs/ folder with architecture notes

Verify your own work: after writing the code, mentally trace through what happens when
a user opens index.html. Does the game loop start? Do controls work? Is something visible?

Write ALL files now.
PROMPT
}

prompt_fix() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION REVIEW FINDINGS:
${VISION_FEEDBACK}
"

    # Focus the fix prompt on the most critical issue
    local focus=""
    if [ "$HEALTH_LOADS" != true ]; then
        focus="CRITICAL: The app fails to load. This is the ONLY thing to fix right now.
Find why it crashes on load and fix it. Nothing else matters until it loads."
    elif [ "$HEALTH_RENDERS" != true ]; then
        focus="CRITICAL: The app loads but shows a BLANK screen. Nothing renders.
Find why nothing is visible and fix it. Check canvas setup, initial draw calls, CSS visibility."
    elif [ "$HEALTH_JS_ERRORS" -gt 0 ]; then
        focus="The app has JavaScript errors. Fix every console error.
Each error is a bug — trace it to the source and fix the root cause, not the symptom."
    elif [ "$HEALTH_INTERACTIVE" != true ]; then
        focus="The app loads and renders but doesn't respond to user input.
Check event listeners, keyboard handlers, game loop state, and input processing."
    else
        focus="Read every file. Find bugs: null refs, broken state transitions, render glitches, input issues.
FIX each bug you find — don't just list them."
    fi

    cat << PROMPT
${ctx}You are fixing bugs in ${OUTPUT_DIR}.

Read ALL source files first.

${focus}${vision_section}

Write fixes directly to the files. List every bug and your fix.

Rate your confidence 1-10 that the app works correctly after your fixes.
PROMPT
}

prompt_improve() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION FEEDBACK:
${VISION_FEEDBACK}
"

    # Pick ONE improvement focus based on maturity
    local focus=""
    case "$(maturity_tier)" in
        early)
            focus="Pick the SINGLE most impactful improvement from this list and do it well:
- Add visual polish (particle effects, smooth animations, glows)
- Add a proper start screen with title and instructions
- Add a game over screen with stats and 'Play Again'
- Store high scores in localStorage"
            ;;
        mid)
            focus="Pick ONE area to improve and do it thoroughly:
- Sound effects via Web Audio API (synthesized, no audio files)
- Difficulty progression that ramps over time
- HUD with animated score/level transitions
- Controls that feel responsive and satisfying"
            ;;
        late)
            focus="Find the WEAKEST part of the user experience and make it great:
- What feels unfinished? Polish it.
- What's confusing? Clarify it.
- What's ugly? Make it beautiful."
            ;;
    esac

    cat << PROMPT
${ctx}You are improving a project in ${OUTPUT_DIR}.

Read ALL source files first.

${focus}${vision_section}

Do ONE thing well. Don't try to do everything at once.

Write changes to ${OUTPUT_DIR}. Describe what you improved and why.

Rate your confidence 1-10 that the improvement works correctly.
PROMPT
}

prompt_test() {
    local ctx
    ctx=$(prompt_context)
    cat << PROMPT
${ctx}You are writing tests for a project in ${OUTPUT_DIR}.

Read ALL source files. Create or update ${OUTPUT_DIR}/test.html.

Use the shared test harness: ${PROJECT_DIR}/lib/test-harness.js (read it first for the API).

Write tests as SAFETY NETS that catch CATEGORIES of problems, not individual bugs.
Each test should protect against an entire class of failure:

const t = new TritiumTest('${PROJECT_NAME}');

// CATEGORY: Initialization — catches all "crash on load" bugs
t.test('app initializes without throwing', function() { ... });

// CATEGORY: Rendering — catches blank screens, missing elements, invisible UI
t.test('visible content renders on screen', function() {
    // Check that canvas has pixels, or DOM has visible elements
});

// CATEGORY: State management — catches broken transitions, stuck states
t.test('all game states are reachable', function() {
    // Verify: menu → playing → paused → game-over → menu
});

// CATEGORY: User input — catches dead controls, missing handlers
t.test('input handlers are registered', function() {
    // Verify keyboard/mouse/touch listeners exist and function
});

// CATEGORY: Data integrity — catches NaN scores, negative lives, overflow
t.test('game data stays valid', function() {
    // Score is a number, lives >= 0, level > 0, no NaN
});

// CATEGORY: Persistence — catches localStorage failures
t.test('data survives page reload', function() {
    // High score saves and loads correctly
});

t.run();

Think: "what NET catches the most fish?" — not "what hook catches one fish?"

Fix any bugs you discover while writing tests.

Write to ${OUTPUT_DIR}. List every test CATEGORY and what class of bugs it catches.
PROMPT
}

prompt_features() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION FEEDBACK:
${VISION_FEEDBACK}
"

    cat << PROMPT
${ctx}You are adding ONE new feature to the project in ${OUTPUT_DIR}.

Read ALL source files first. Understand what exists.

Choose the SINGLE most impactful feature that's missing. Examples:
- A new gameplay mechanic, power-up, or mode
- Particle effects, explosions, or visual feedback
- Procedural background music via Web Audio API
- Mobile/touch controls
- A settings menu

Add ONE feature. Implement it completely. Test that it works with the existing code.
Do NOT break what already works.${vision_section}

Write changes to ${OUTPUT_DIR}. Describe the feature and why you chose it.

Rate your confidence 1-10 that the feature works without breaking anything.
PROMPT
}

prompt_polish() {
    local ctx
    ctx=$(prompt_context)
    local vision_section=""
    [ -n "$VISION_FEEDBACK" ] && vision_section="

VISION MODEL REVIEW:
${VISION_FEEDBACK}"

    # Build screenshot markdown references if screenshots/ exists
    local ss_section=""
    if [ -d "${OUTPUT_DIR}/screenshots" ]; then
        local ss_files
        ss_files=$(find "${OUTPUT_DIR}/screenshots" -name '*.png' 2>/dev/null | sort)
        if [ -n "$ss_files" ]; then
            ss_section="

SCREENSHOTS: The screenshots/ folder contains captured screenshots of the project.
Update ${OUTPUT_DIR}/README.md to include them. Use relative paths like:
![Desktop 1080p](screenshots/desktop-1080p_01_initial_load.png)
![Gameplay](screenshots/desktop-720p_05_during_gameplay.png)

Available screenshots:"
            while IFS= read -r ss_file; do
                ss_section="${ss_section}
  - screenshots/$(basename "$ss_file")"
            done <<< "$ss_files"
        fi
    fi

    cat << PROMPT
${ctx}Final polish pass on the project in ${OUTPUT_DIR}.

Read ALL source files.

Pretend you are a user opening this for the first time. Walk through the ENTIRE experience:

1. Open index.html — what do you see? Is it clear what this is and how to start?
2. Start the app/game — is the transition smooth? Any flash of unstyled content?
3. Use it for 30 seconds — is it satisfying? What feels off?
4. Try to pause, restart, navigate — does everything you'd expect actually work?
5. Look at the visual design — does it look professional or amateur? Be honest.

Fix the SINGLE biggest UX problem you find. Do it thoroughly.

Also: update README.md with features list and screenshots if available.${ss_section}${vision_section}

Write changes to ${OUTPUT_DIR}.

Rate the project 1-10 from a USER's perspective (not code quality — user experience).
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
${ctx}You are validating a project in ${OUTPUT_DIR}.

${test_info}

TRUST NOTHING. The code may claim to work but actually be broken. Verify everything from a USER'S perspective.

YOUR JOB: Act as a user, not a code reviewer. Actually run things and check results.

1. If test.html exists, actually EXECUTE it (open in headless browser or run the tests)
2. If Python tests exist, run them: cd ${OUTPUT_DIR} && python3 -m pytest
3. If no tests exist, CREATE them (use ${PROJECT_DIR}/lib/test-harness.js for web projects)

Validate from the USER's perspective:
- Can a user actually start the app/game? (not "does the code look right" — actually try it)
- Do the controls actually work? (not "are event listeners attached" — simulate input)
- Does the score/state actually update? (not "there's a scoring function" — verify the output)
- Can the user pause, restart, see their score?
- What would a real user's FIRST 30 seconds look like?

For ANY failure: find root cause, FIX it, re-run to verify.

Write fixes to ${OUTPUT_DIR}. Report what passed, what failed, what you fixed.

Rate your confidence 1-10 that a real user would have a good experience.
PROMPT
}

prompt_refactor() {
    local ctx
    ctx=$(prompt_context)

    # Build specific file size info
    local file_info=""
    if [ -n "$HEALTH_FILE_SIZES" ]; then
        file_info="
These files are too large and MUST be split:${HEALTH_FILE_SIZES}
"
    else
        # Measure now if we haven't
        measure_files
        if [ -n "$HEALTH_FILE_SIZES" ]; then
            file_info="
These files are too large and MUST be split:${HEALTH_FILE_SIZES}
"
        fi
    fi

    cat << PROMPT
${ctx}You are refactoring the project in ${OUTPUT_DIR}.

Read ALL source files first.
${file_info}
YOUR JOB: Improve code structure WITHOUT changing behavior.

Split large files into focused modules:
- Separate game logic from rendering from input handling
- Extract reusable utilities into their own files
- Use ES modules (import/export) or separate <script> tags
- Each file should have ONE clear responsibility

Rules:
- Do NOT change what the app does — only HOW the code is organized
- Do NOT add new features
- Test that the app still works after refactoring
- Update any imports/references to match new file structure

Write changes to ${OUTPUT_DIR}. List every file you created, modified, or removed.
PROMPT
}

prompt_consolidate() {
    local ctx
    ctx=$(prompt_context)

    cat << PROMPT
${ctx}You are cleaning up the project in ${OUTPUT_DIR}.

Read ALL source files carefully.

YOUR JOB: Remove waste. Find and eliminate:
- Dead code (functions/variables that are never called)
- Duplicate logic (same thing implemented twice)
- Unused CSS rules
- Commented-out code blocks
- Console.log statements left from debugging
- Redundant event listeners
- Variables declared but never used

Rules:
- Do NOT change behavior — only remove what's truly unused
- Do NOT add anything new
- If unsure whether something is used, leave it

Write changes to ${OUTPUT_DIR}. List everything you removed and why it was dead.
PROMPT
}

prompt_docs() {
    local ctx
    ctx=$(prompt_context)

    # Build list of available screenshots
    local ss_list=""
    if [ -d "${OUTPUT_DIR}/screenshots" ]; then
        local ss_files
        ss_files=$(find "${OUTPUT_DIR}/screenshots" -name '*.png' 2>/dev/null | sort)
        if [ -n "$ss_files" ]; then
            ss_list="

Available screenshots in screenshots/:"
            while IFS= read -r ss_file; do
                ss_list="${ss_list}
  - screenshots/$(basename "$ss_file")"
            done <<< "$ss_files"
        fi
    fi

    cat << PROMPT
${ctx}You are updating documentation for the project in ${OUTPUT_DIR}.

Read ALL source files and any existing docs/ and README.md.

YOUR JOB: Make sure this project is well-documented.

1. README.md (project root) — must include:
   - Project title and one-line description
   - How to run it (open index.html, etc.)
   - Controls / usage instructions
   - Full features list (everything the project does)
   - Screenshots section with embedded images from screenshots/ folder
   - Known issues or limitations (if any)

2. docs/ folder — create or update:
   - Architecture overview (how the code is structured, key modules)
   - Any design decisions worth documenting
${ss_list}

For screenshots in README.md, use relative paths:
![Title Screen](screenshots/desktop-1080p_01_initial_load.png)
![Gameplay](screenshots/desktop-720p_05_during_gameplay.png)
![Mobile View](screenshots/mobile-iphone_01_initial_load.png)

Include screenshots at multiple resolutions to show responsiveness.

Write all changes to ${OUTPUT_DIR}.

List every doc file you created or updated.
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
#  Main loop — dynamic phase selection
#
#  Each cycle:
#    1. Health check (does it work?)
#    2. Select phase based on health + maturity + signals
#    3. Run ONE focused prompt (ask for 1 thing, do it well)
#    4. Git checkpoint on constructive phases
#    5. Vision gate on polish/runtests (when app should be good)
#
#  Philosophy: trade time for quality. One thing done right > many things half-done.
# =============================================================================

while [ "$(time_remaining)" -gt 300 ]; do
    CYCLE=$((CYCLE + 1))
    remaining=$(time_remaining)

    # ----- HEALTH CHECK (every cycle — this is how we know it works) -----
    if [ "$CAN_SCREENSHOT" = true ] || [ "$CYCLE" -eq 1 ]; then
        run_health_check
    fi

    # ----- SELECT PHASE (based on health, maturity, signals) -----
    phase=$(select_phase)

    echo ""
    log_to "================================================================"
    log_to "CYCLE  #${CYCLE}  phase=${phase}  health=${HEALTH_STATUS}  tier=$(maturity_tier)  elapsed=$(($(elapsed_secs) / 60))m  remaining=$((remaining / 60))m"
    log_to "================================================================"

    # ----- CODE PASS (coder model stays loaded) -----
    load_model "$CODER_MODEL"

    local_prompt=""
    case "$phase" in
        fix)          local_prompt=$(prompt_fix) ;;
        improve)      local_prompt=$(prompt_improve) ;;
        test)         local_prompt=$(prompt_test) ;;
        runtests)     local_prompt=$(prompt_runtests) ;;
        features)     local_prompt=$(prompt_features) ;;
        polish)       local_prompt=$(prompt_polish) ;;
        docs)         local_prompt=$(prompt_docs) ;;
        refactor)     local_prompt=$(prompt_refactor) ;;
        consolidate)  local_prompt=$(prompt_consolidate) ;;
    esac

    iter_timeout=900
    remaining=$(time_remaining)
    [ "$remaining" -lt "$iter_timeout" ] && iter_timeout=$remaining

    log_to "CODE   phase=${phase} timeout=${iter_timeout}"
    response=$(agent_code "$local_prompt" "$iter_timeout")

    if [ -n "$response" ]; then
        log_to "CODE   response_len=${#response}"
        # Extract summary and confidence score
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

        # Try to extract confidence score from response
        local score
        score=$(echo "$response" | python3 -c "
import sys,re
text = sys.stdin.read()
# Look for patterns like 'confidence: 8' or 'confidence 8/10' or 'rate: 7'
m = re.search(r'(?:confidence|rate)[:\s]+(\d+)', text, re.IGNORECASE)
if m: print(m.group(1))
else: print('')
" 2>/dev/null || echo "")
        [ -n "$score" ] && record_score "$phase" "$score"
    else
        log_to "CODE   response=EMPTY (may have timed out)"
        record_cycle "$phase" "No response (timeout or error)"
    fi

    # ----- GIT CHECKPOINT (after constructive phases) -----
    case "$phase" in
        improve|features|polish|docs|refactor|consolidate)
            git_checkpoint "cycle-${CYCLE}-${phase}"
            ;;
    esac

    # ----- VISION GATE (after polish or runtests — when app should be in good shape) -----
    if [ "$phase" = "runtests" ] || [ "$phase" = "polish" ]; then
        if [ "$HEALTH_STATUS" != "FAIL" ]; then
            log_to "VISION GATE triggered after ${phase} phase"
            run_vision_gate
            # If vision produced feedback, run an immediate fix pass
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
                VISION_FEEDBACK=""
            fi
        else
            log_to "VISION GATE skipped — app is broken (health=FAIL)"
        fi
    fi

    # Brief pause
    sleep 3
done

# =============================================================================
#  Final health check + summary
# =============================================================================

TOTAL_TIME=$(elapsed_secs)

# Run one final health check to know the ending state
run_health_check
log_to "FINAL HEALTH: ${HEALTH_STATUS} — ${HEALTH_DETAILS}"

# Final git checkpoint
git_checkpoint "final — ${CYCLE} cycles in $((TOTAL_TIME / 60))m — health:${HEALTH_STATUS}"

log_to "DONE   cycles=${CYCLE} total_time=${TOTAL_TIME}s health=${HEALTH_STATUS}"

echo ""
echo "=========================================="
echo "  Iteration complete: ${PROJECT_NAME}"
echo "  Cycles:    ${CYCLE}"
echo "  Duration:  $((TOTAL_TIME / 60)) minutes"
echo "  Output:    ${OUTPUT_DIR}"
echo "  Health:    ${HEALTH_STATUS}"
echo "=========================================="
echo ""
echo "  Health details: ${HEALTH_DETAILS}"
echo ""
echo "  Files:"
find "$OUTPUT_DIR" -type f -not -path '*/screenshots/*' | sort | while read -r f; do
    local size lines
    size=$(wc -c < "$f")
    lines=$(wc -l < "$f" 2>/dev/null || echo "?")
    local rel="${f#${OUTPUT_DIR}/}"
    echo "    ${rel}  (${size} bytes, ${lines} lines)"
done
echo ""
if [ -d "${OUTPUT_DIR}/screenshots" ]; then
    ss_count=$(find "${OUTPUT_DIR}/screenshots" -name '*.png' 2>/dev/null | wc -l)
    echo "  Screenshots: ${ss_count} in ${OUTPUT_DIR}/screenshots/"
fi
if [ -f "${OUTPUT_DIR}/README.md" ]; then
    echo "  README:      ${OUTPUT_DIR}/README.md"
fi
if [ -d "${OUTPUT_DIR}/docs" ]; then
    echo "  Docs:        ${OUTPUT_DIR}/docs/"
fi
if [ -n "$PHASE_SCORES" ]; then
    echo ""
    echo "  Confidence scores:"
    echo "$PHASE_SCORES" | while IFS=: read -r p s; do
        [ -n "$p" ] && echo "    ${p}: ${s}/10"
    done
fi
echo ""
echo "  View: python3 -m http.server 8080 -d ${OUTPUT_DIR}"
echo "  Logs: ${LOG_FILE}"
echo ""
