#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Shared UI & Utility Library
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

# --- Colors & Symbols ---
if [[ -t 1 ]]; then
    RST='\033[0m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RED='\033[0;31m'
    GRN='\033[0;32m'
    YLW='\033[0;33m'
    BLU='\033[0;34m'
    MAG='\033[0;35m'
    CYN='\033[0;36m'
    WHT='\033[1;37m'
    BGBLK='\033[40m'
    BRED='\033[1;31m'
    BGRN='\033[1;32m'
    BYLW='\033[1;33m'
    BBLU='\033[1;34m'
    BMAG='\033[1;35m'
    BCYN='\033[1;36m'
else
    RST='' BOLD='' DIM='' RED='' GRN='' YLW='' BLU='' MAG='' CYN='' WHT=''
    BGBLK='' BRED='' BGRN='' BYLW='' BBLU='' BMAG='' BCYN=''
fi

SYM_OK="${BGRN}[OK]${RST}"
SYM_FAIL="${BRED}[!!]${RST}"
SYM_WARN="${BYLW}[!!]${RST}"
SYM_RUN="${BBLU}[>>]${RST}"
SYM_INFO="${BCYN}[--]${RST}"
SYM_SKIP="${DIM}[--]${RST}"

# --- Structured event log ---
# Appends plain-text timestamped lines to logs/tritium.log.
# Called automatically by log_ok/fail/warn/run, or directly for extra detail.
TRITIUM_LOG=""  # set after LOG_DIR is defined below

tlog() {
    [ -z "$TRITIUM_LOG" ] && return
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    # Strip ANSI color codes for the log file
    local clean
    clean=$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')
    echo "[$ts] $clean" >> "$TRITIUM_LOG"
}

# --- Logging (terminal + event log) ---
log_ok()   { echo -e "  ${SYM_OK}  $*"; tlog "OK    $*"; }
log_fail() { echo -e "  ${SYM_FAIL}  ${RED}$*${RST}"; tlog "FAIL  $*"; }
log_warn() { echo -e "  ${SYM_WARN}  ${YLW}$*${RST}"; tlog "WARN  $*"; }
log_run()  { echo -e "  ${SYM_RUN}  $*"; tlog "RUN   $*"; }
log_info() { echo -e "  ${SYM_INFO}  ${DIM}$*${RST}"; }
log_skip() { echo -e "  ${SYM_SKIP}  ${DIM}$*${RST}"; }

# --- Section header ---
section() {
    echo ""
    echo -e "  ${BMAG}---${RST} ${BOLD}$*${RST} ${BMAG}---${RST}"
    echo ""
}

# --- Banner ---
banner() {
    local width=62
    echo ""
    echo -e "  ${BMAG}+$(printf '%0.s-' $(seq 1 $width))+"
    echo -e "  |${RST}  ${BOLD}${WHT}TRITIUM CODER${RST}  ${DIM}Local AI Coding Stack${RST}                        ${BMAG}|"
    echo -e "  |${RST}  ${CYN}Ollama${RST} + ${CYN}Claude Code${RST} + ${CYN}Playwright${RST}                            ${BMAG}|"
    echo -e "  |${RST}  ${DIM}(c) 2026 Matthew Valancy  |  Valpatel Software${RST}              ${BMAG}|"
    echo -e "  +$(printf '%0.s-' $(seq 1 $width))+"
    echo -e "  |${RST}  ${DIM}MIT License${RST}  ${CYN}github.com/mvalancy/tritium-coder${RST}              ${BMAG}|"
    echo -e "  +$(printf '%0.s-' $(seq 1 $width))+${RST}"
    echo ""
}

# --- Spinner (for long operations) ---
spin() {
    local pid=$1
    local msg="${2:-Working...}"
    local frames=('/' '-' '\' '|')
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${BBLU}[${frames[$i]}]${RST}  ${msg}  "
        i=$(( (i + 1) % 4 ))
        sleep 0.15
    done
    tput cnorm 2>/dev/null || true
    echo -ne "\r\033[2K"
}

# --- Ask yes/no ---
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    echo -ne "  ${BYLW}[??]${RST}  ${prompt} ${DIM}${hint}${RST} "
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# --- Check a command exists ---
require_cmd() {
    local cmd="$1"
    local name="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# --- Safe directory creation ---
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

# --- Project paths ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
PROXY_DIR="$PROJECT_DIR/.proxy"
LOG_DIR="$PROJECT_DIR/logs"
CONFIG_DIR="$PROJECT_DIR/config"

# Initialize event log (now that LOG_DIR is set)
ensure_dir "$LOG_DIR"
TRITIUM_LOG="$LOG_DIR/tritium.log"

# Trim log if over 1000 lines — keep the most recent 500
if [ -f "$TRITIUM_LOG" ] && [ "$(wc -l < "$TRITIUM_LOG")" -gt 1000 ]; then
    tail -n 500 "$TRITIUM_LOG" > "$TRITIUM_LOG.tmp"
    mv "$TRITIUM_LOG.tmp" "$TRITIUM_LOG"
fi

# --- Load persistent env overrides (.tritium.env) ---
TRITIUM_ENV="$PROJECT_DIR/.tritium.env"
if [ -f "$TRITIUM_ENV" ]; then
    # shellcheck source=/dev/null
    source "$TRITIUM_ENV"
fi

# --- Timing helpers ---
_timer_start=0
timer_start() { _timer_start=$(date +%s); }
timer_elapsed() {
    local now
    now=$(date +%s)
    echo $(( now - _timer_start ))
}

OLLAMA_MODEL_NAME="qwen3-coder-next"
PROXY_PORT=8082
PANEL_PORT=18790

# --- Network helpers ---
# Determine bind address: 0.0.0.0 if Tailscale is online (private network),
# 127.0.0.1 otherwise. Checked at runtime so it picks up Tailscale installed
# after initial setup.
get_bind_addr() {
    if command -v tailscale &>/dev/null; then
        local online
        online=$(tailscale status --json 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('Online',False))" 2>/dev/null || echo "")
        if [ "$online" = "True" ]; then
            echo "0.0.0.0"
            return
        fi
    fi
    echo "127.0.0.1"
}

# --- HTTP helpers ---
# curl with sane timeouts so scripts don't hang if a service is unresponsive
curl_check() {
    curl -s --connect-timeout 3 --max-time 5 "$@"
}

# --- Ollama helpers ---
# ollama list | grep -q triggers SIGPIPE with pipefail (grep -q closes pipe
# early while ollama is still writing). Capture output first to avoid this.
ollama_has_model() {
    local models
    models=$(ollama list 2>/dev/null) || return 1
    echo "$models" | grep -q "$1"
}

ollama_model_size() {
    local models
    models=$(ollama list 2>/dev/null) || return 1
    echo "$models" | grep "$1" | awk '{print $3, $4}'
}

ollama_model_loaded() {
    local ps ollama_url
    ollama_url=$(get_ollama_url)
    ps=$(curl_check "$ollama_url/api/ps" 2>/dev/null) || return 1
    echo "$ps" | grep -q "$1"
}

# --- Port check helper ---
port_listening() {
    ss -tlnp 2>/dev/null | grep -q ":${1} "
}

# =========================================================================
#  Hardware detection functions
# =========================================================================

detect_ram_gb() {
    free -g 2>/dev/null | awk '/^Mem:/ {print $2}'
}

detect_gpu_name() {
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1
}

detect_vram_mb() {
    local total=0
    while IFS= read -r mb; do
        # Skip non-numeric values (e.g. "N/A" on unified memory systems)
        [[ "$mb" =~ ^[0-9]+$ ]] && total=$(( total + mb ))
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
    echo "$total"
}

detect_unified_memory() {
    local gpu
    gpu=$(detect_gpu_name)
    if echo "$gpu" | grep -qiE 'GB10|GB20|Jetson|Tegra|Grace'; then
        echo "true"
    else
        echo "false"
    fi
}

detect_available_memory_gb() {
    if [ "$(detect_unified_memory)" = "true" ]; then
        detect_ram_gb
    else
        local vram_mb
        vram_mb=$(detect_vram_mb)
        echo $(( vram_mb / 1024 ))
    fi
}

detect_hw_tier() {
    local avail_gb
    avail_gb=$(detect_available_memory_gb)
    if [ "$avail_gb" -ge 96 ] 2>/dev/null; then
        echo "full"
    elif [ "$avail_gb" -ge 32 ] 2>/dev/null; then
        echo "mid"
    elif [ "$avail_gb" -ge 16 ] 2>/dev/null; then
        echo "low"
    else
        echo "insufficient"
    fi
}

detect_disk_gb() {
    df -BG "$PROJECT_DIR" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

get_ollama_url() {
    echo "${OLLAMA_HOST:-http://localhost:11434}"
}

# =========================================================================
#  Service ensure functions — idempotent, used by start.sh and dashboard.sh
# =========================================================================

ensure_ollama() {
    local ollama_url
    ollama_url=$(get_ollama_url)
    if curl_check "$ollama_url/api/tags" &>/dev/null; then
        log_ok "Ollama server ${DIM}(${ollama_url})${RST}"
        return 0
    fi
    # Remote mode: don't try to start locally
    if [ "$ollama_url" != "http://localhost:11434" ]; then
        log_fail "Remote Ollama at ${ollama_url} is not reachable"
        return 1
    fi
    timer_start
    log_run "Starting Ollama server..."
    ensure_dir "$LOG_DIR"
    ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
    for _ in $(seq 1 15); do
        curl_check "$ollama_url/api/tags" &>/dev/null && break
        sleep 1
    done
    if curl_check "$ollama_url/api/tags" &>/dev/null; then
        log_ok "Ollama server started ($(timer_elapsed)s)"
        return 0
    fi
    log_fail "Ollama server failed to start after $(timer_elapsed)s. Check $LOG_DIR/ollama.log"
    return 1
}

ensure_model() {
    if ! ollama_has_model "$OLLAMA_MODEL_NAME"; then
        log_fail "Model '${OLLAMA_MODEL_NAME}' not found in Ollama."
        log_info "Run ${CYN}./install.sh${RST} first to download it."
        return 1
    fi
    # Skip warmup if already loaded
    if ollama_model_loaded "$OLLAMA_MODEL_NAME"; then
        log_ok "Model '${OLLAMA_MODEL_NAME}' loaded"
        return 0
    fi
    timer_start
    log_run "Loading model into memory (may take 1-3 minutes)..."
    ollama run "$OLLAMA_MODEL_NAME" "Respond with only: READY" > /tmp/.tritium-warmup 2>/dev/null &
    local pid=$!
    spin "$pid" "Loading ${OLLAMA_MODEL_NAME} into GPU memory..."
    wait "$pid" 2>/dev/null || true
    local response elapsed
    response=$(cat /tmp/.tritium-warmup 2>/dev/null || echo "")
    rm -f /tmp/.tritium-warmup
    elapsed=$(timer_elapsed)
    if [ -n "$response" ]; then
        log_ok "Model loaded and responding (${elapsed}s)"
    else
        log_warn "Model loaded but gave empty response after ${elapsed}s (may still work)"
    fi
    return 0
}

ensure_proxy() {
    if port_listening "$PROXY_PORT"; then
        log_ok "Claude Code proxy :${PROXY_PORT}"
        return 0
    fi
    if [ ! -f "$PROXY_DIR/start_proxy.py" ]; then
        log_fail "Proxy not installed. Run ${CYN}./install.sh${RST} first."
        return 1
    fi
    if [ ! -d "$PROXY_DIR/.venv" ]; then
        log_fail "Proxy venv not set up. Run ${CYN}./install.sh${RST} first."
        return 1
    fi
    timer_start
    log_run "Starting Claude Code proxy on port ${PROXY_PORT}..."
    ensure_dir "$LOG_DIR"
    (
        cd "$PROXY_DIR"
        source .venv/bin/activate
        nohup python start_proxy.py > "$LOG_DIR/proxy.log" 2>&1 &
        echo $! > "$LOG_DIR/proxy.pid"
    )
    for _ in $(seq 1 10); do
        port_listening "$PROXY_PORT" && break
        sleep 1
    done
    if port_listening "$PROXY_PORT"; then
        log_ok "Proxy started on port ${PROXY_PORT} ($(timer_elapsed)s)"
        return 0
    fi
    log_fail "Proxy failed to start after $(timer_elapsed)s. Check $LOG_DIR/proxy.log"
    return 1
}

ensure_panel() {
    if port_listening "$PANEL_PORT"; then
        log_ok "Control panel :${PANEL_PORT}"
        return 0
    fi
    local panel_dir="$PROJECT_DIR/web"
    if [ ! -f "$panel_dir/index.html" ]; then
        log_warn "Control panel files not found"
        return 1
    fi
    local bind_addr
    bind_addr=$(get_bind_addr)
    log_run "Starting control panel on port ${PANEL_PORT}..."
    ensure_dir "$LOG_DIR"
    (
        cd "$panel_dir"
        nohup python3 -m http.server "$PANEL_PORT" --bind "$bind_addr" > "$LOG_DIR/panel.log" 2>&1 &
        echo $! > "$LOG_DIR/panel.pid"
    )
    sleep 1
    if port_listening "$PANEL_PORT"; then
        log_ok "Control panel started on port ${PANEL_PORT}"
        return 0
    fi
    log_warn "Control panel may not have started. Check $LOG_DIR/panel.log"
    return 1
}

# Start all services. Returns 0 if core services (Ollama + proxy) are up.
ensure_stack() {
    ensure_dir "$LOG_DIR"
    local stack_start
    stack_start=$(date +%s)
    tlog "--- ensure_stack started ($(basename "$0")) ---"
    local ok=true
    ensure_ollama  || ok=false
    if [ "$ok" = true ]; then
        ensure_model || true
    fi
    ensure_proxy   || ok=false
    ensure_panel   || true
    local stack_elapsed=$(( $(date +%s) - stack_start ))
    tlog "--- ensure_stack finished (${stack_elapsed}s total) ---"
    return 0
}
