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

# --- Logging ---
log_ok()   { echo -e "  ${SYM_OK}  $*"; }
log_fail() { echo -e "  ${SYM_FAIL}  ${RED}$*${RST}"; }
log_warn() { echo -e "  ${SYM_WARN}  ${YLW}$*${RST}"; }
log_run()  { echo -e "  ${SYM_RUN}  $*"; }
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
    echo -e "  |${RST}  ${CYN}Ollama${RST} + ${CYN}Claude Code${RST} + ${CYN}OpenClaw${RST}                             ${BMAG}|"
    echo -e "  |${RST}  ${DIM}(c) 2026 Matthew Valancy  |  Valpatel Software${RST}              ${BMAG}|"
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

OLLAMA_MODEL_NAME="qwen3-coder-next"
PROXY_PORT=8082
GATEWAY_PORT=18789
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

# Gateway bind mode: "all" if Tailscale is online, "loopback" otherwise.
get_gateway_bind() {
    if [ "$(get_bind_addr)" = "0.0.0.0" ]; then
        echo "all"
    else
        echo "loopback"
    fi
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
    local ps
    ps=$(curl_check http://localhost:11434/api/ps 2>/dev/null) || return 1
    echo "$ps" | grep -q "$1"
}

# --- Port check helper ---
port_listening() {
    ss -tlnp 2>/dev/null | grep -q ":${1} "
}

# =========================================================================
#  Service ensure functions — idempotent, used by start.sh and dashboard.sh
# =========================================================================

ensure_ollama() {
    if curl_check http://localhost:11434/api/tags &>/dev/null; then
        log_ok "Ollama server"
        return 0
    fi
    log_run "Starting Ollama server..."
    ensure_dir "$LOG_DIR"
    ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
    for _ in $(seq 1 15); do
        curl_check http://localhost:11434/api/tags &>/dev/null && break
        sleep 1
    done
    if curl_check http://localhost:11434/api/tags &>/dev/null; then
        log_ok "Ollama server started"
        return 0
    fi
    log_fail "Ollama server failed to start. Check $LOG_DIR/ollama.log"
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
    log_run "Loading model into memory (may take 1-3 minutes)..."
    ollama run "$OLLAMA_MODEL_NAME" "Respond with only: READY" > /tmp/.tritium-warmup 2>/dev/null &
    local pid=$!
    spin "$pid" "Loading ${OLLAMA_MODEL_NAME} into GPU memory..."
    wait "$pid" 2>/dev/null || true
    local response
    response=$(cat /tmp/.tritium-warmup 2>/dev/null || echo "")
    rm -f /tmp/.tritium-warmup
    if [ -n "$response" ]; then
        log_ok "Model loaded and responding"
    else
        log_warn "Model loaded but gave empty response (may still work)"
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
        log_ok "Proxy started on port ${PROXY_PORT}"
        return 0
    fi
    log_fail "Proxy failed to start. Check $LOG_DIR/proxy.log"
    return 1
}

ensure_gateway() {
    if port_listening "$GATEWAY_PORT"; then
        log_ok "OpenClaw gateway :${GATEWAY_PORT}"
        return 0
    fi
    if ! command -v openclaw &>/dev/null; then
        log_warn "OpenClaw not installed (optional)"
        return 1
    fi
    local gw_bind
    gw_bind=$(get_gateway_bind)
    # Apply hardened config if not present
    local oc_config="$HOME/.openclaw/openclaw.json"
    if [ ! -f "$oc_config" ]; then
        mkdir -p "$HOME/.openclaw"
        sed -e "s/qwen3-coder-next/${OLLAMA_MODEL_NAME}/g" \
            -e "s/\"bind\": \"loopback\"/\"bind\": \"${gw_bind}\"/" \
            "$CONFIG_DIR/openclaw.json" > "$oc_config"
    fi
    log_run "Starting OpenClaw gateway (bind ${gw_bind})..."
    ensure_dir "$LOG_DIR"
    (
        cd "$PROJECT_DIR"
        nohup openclaw gateway run --bind "$gw_bind" > "$LOG_DIR/openclaw-gateway.log" 2>&1 &
        echo $! > "$LOG_DIR/openclaw-gateway.pid"
    )
    for _ in $(seq 1 8); do
        port_listening "$GATEWAY_PORT" && break
        sleep 1
    done
    if port_listening "$GATEWAY_PORT"; then
        log_ok "OpenClaw gateway started on port ${GATEWAY_PORT}"
        return 0
    fi
    log_warn "OpenClaw gateway may not have started. Check $LOG_DIR/openclaw-gateway.log"
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
    local ok=true
    ensure_ollama  || ok=false
    if [ "$ok" = true ]; then
        ensure_model || true
    fi
    ensure_proxy   || ok=false
    ensure_gateway || true
    ensure_panel   || true
    return 0
}
