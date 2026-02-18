#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Stack Status
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}./status${RST} — Show stack status, resources, and access info"
    echo ""
    echo -e "  Checks which services are running, shows system resources (memory,"
    echo -e "  disk, GPU), lists local and Tailscale access URLs, and prints"
    echo -e "  quick commands for controlling the stack and submitting jobs."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./status"
    echo ""
    echo -e "  ${BOLD}See also:${RST}  ./start, ./stop, ./dashboard"
    echo ""
    exit 0
fi

banner
echo -e "  ${DIM}Service health, system resources, access URLs, and quick commands.${RST}"
echo ""

section "Service Status"

# --- Ollama Server ---
if curl_check http://localhost:11434/api/tags &>/dev/null; then
    log_ok "Ollama server       ${BGRN}running${RST}  ${DIM}http://localhost:11434${RST}"
else
    log_fail "Ollama server       ${RED}stopped${RST}"
fi

# --- Model loaded ---
LOADED=$(curl_check http://localhost:11434/api/ps 2>/dev/null | grep -o "\"$OLLAMA_MODEL_NAME" || echo "")
if [ -n "$LOADED" ]; then
    log_ok "Model               ${BGRN}loaded${RST}   ${DIM}${OLLAMA_MODEL_NAME}${RST}"
else
    if ollama_has_model "$OLLAMA_MODEL_NAME"; then
        log_warn "Model               ${YLW}available (not loaded)${RST}  ${DIM}${OLLAMA_MODEL_NAME}${RST}"
    else
        log_fail "Model               ${RED}not installed${RST}  ${DIM}${OLLAMA_MODEL_NAME}${RST}"
    fi
fi

# --- Proxy ---
if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
    log_ok "Claude Code proxy   ${BGRN}running${RST}  ${DIM}http://localhost:${PROXY_PORT}${RST}"
else
    log_fail "Claude Code proxy   ${RED}stopped${RST}"
fi

# --- Control Panel ---
if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} "; then
    log_ok "Control panel       ${BGRN}running${RST}  ${DIM}http://localhost:${PANEL_PORT}${RST}"
else
    log_warn "Control panel       ${YLW}stopped${RST}  ${DIM}(start with: ./dashboard)${RST}"
fi

section "System Resources"

# --- Memory ---
TOTAL_MEM=$(free -g | awk '/^Mem:/ {print $2}')
USED_MEM=$(free -g | awk '/^Mem:/ {print $3}')
AVAIL_MEM=$(free -g | awk '/^Mem:/ {print $7}')
log_info "Memory: ${BOLD}${USED_MEM}G${RST}${DIM} used / ${AVAIL_MEM}G available / ${TOTAL_MEM}G total${RST}"

# --- Disk ---
DISK_AVAIL=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
DISK_USED=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $3}')
log_info "Disk:   ${BOLD}${DISK_USED}${RST}${DIM} used / ${DISK_AVAIL} available${RST}"

# --- GPU ---
GPU_INFO=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || echo "N/A")
log_info "GPU:    ${DIM}${GPU_INFO}${RST}"

section "Access"

# --- Local URLs ---
if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} "; then
    log_info "Control panel       ${CYN}http://localhost:${PANEL_PORT}${RST}"
else
    log_info "Control panel       ${DIM}not running${RST}  ${DIM}(start with: ./dashboard)${RST}"
fi
log_info "Ollama API          ${CYN}http://localhost:11434${RST}"
log_info "Proxy API           ${CYN}http://localhost:${PROXY_PORT}${RST}"

# --- Tailscale ---
if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$TS_STATUS" ]; then
        TS_NAME=$(echo "$TS_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
        TS_IP=$(echo "$TS_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); ips=d.get('TailscaleIPs',[]); print(ips[0] if ips else '')" 2>/dev/null || echo "")
        TS_ONLINE=$(echo "$TS_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online',False))" 2>/dev/null || echo "")

        if [ "$TS_ONLINE" = "True" ] && [ -n "$TS_NAME" ]; then
            echo ""
            log_ok "Tailscale           ${BGRN}online${RST}  ${DIM}${TS_NAME}${RST}"
            [ -n "$TS_IP" ] && log_info "Tailscale IP        ${CYN}${TS_IP}${RST}"
            log_info "Remote panel        ${CYN}http://${TS_NAME}:${PANEL_PORT}${RST}"
        else
            log_warn "Tailscale           ${YLW}installed but offline${RST}"
        fi
    else
        log_warn "Tailscale           ${YLW}installed but not connected${RST}"
    fi
else
    log_info "Tailscale           ${DIM}not installed${RST}  ${DIM}(install for remote access)${RST}"
fi

section "Quick Commands"

log_info "Start stack         ${BOLD}./start${RST}"
log_info "Stop stack          ${BOLD}./stop${RST}"
log_info "Control panel       ${BOLD}./dashboard${RST}"
log_info "Run tests           ${BOLD}./test${RST}"
echo ""
log_info "Claude Code session ${BOLD}scripts/run-claude.sh${RST}"
log_info "  (in a project)    ${BOLD}scripts/run-claude.sh -p /path/to/project${RST}"
log_info "Build a project     ${BOLD}./iterate \"Build a Tetris game\" --hours 4${RST}"
echo ""
log_info "Tail logs           ${BOLD}tail -f logs/proxy.log${RST}"

section "Installed Components"

# Check each tool
for cmd_pair in "ollama:Ollama" "python3:Python" "node:Node.js" "claude:Claude Code CLI" "git:Git"; do
    cmd="${cmd_pair%%:*}"
    name="${cmd_pair##*:}"
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        log_ok "${name}  ${DIM}${ver}${RST}"
    else
        log_fail "${name}  ${RED}not found${RST}"
    fi
done

echo ""
