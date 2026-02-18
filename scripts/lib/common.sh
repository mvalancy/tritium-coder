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
