#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Stop Local AI Stack
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}./stop${RST} — Stop all services and free GPU memory"
    echo ""
    echo -e "  Stops the control panel, Claude Code proxy, and OpenClaw gateway."
    echo -e "  Unloads the model from GPU memory but leaves Ollama server running."
    echo -e "  Safe to run multiple times — already-stopped services are skipped."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./stop"
    echo ""
    echo -e "  ${BOLD}Note:${RST}   Ollama server is left running so other models remain available."
    echo -e "          Full stop: ${CYN}systemctl stop ollama${RST} or ${CYN}pkill ollama${RST}"
    echo ""
    echo -e "  ${BOLD}See also:${RST}  ./start, ./status"
    echo ""
    exit 0
fi

banner
tlog "--- stop.sh started ---"
echo -e "  ${DIM}Stopping proxy, gateway, and panel. Unloading model from GPU memory.${RST}"
echo ""

section "Shutting Down"

# --- Stop control panel ---
if pgrep -f "python3 -m http.server ${PANEL_PORT}" &>/dev/null; then
    pkill -f "python3 -m http.server ${PANEL_PORT}" 2>/dev/null || true
    log_ok "Control panel stopped"
else
    log_skip "Panel was not running"
fi
rm -f "$LOG_DIR/panel.pid"

# --- Stop proxy ---
if pgrep -f "start_proxy.py" &>/dev/null; then
    pkill -f "start_proxy.py" 2>/dev/null || true
    sleep 1
    if pgrep -f "start_proxy.py" &>/dev/null; then
        pkill -9 -f "start_proxy.py" 2>/dev/null || true
    fi
    log_ok "Claude Code proxy stopped"
else
    log_skip "Proxy was not running"
fi
rm -f "$LOG_DIR/proxy.pid"

# --- Stop OpenClaw gateway ---
if pgrep -f "openclaw.*gateway" &>/dev/null; then
    pkill -f "openclaw.*gateway" 2>/dev/null || true
    sleep 1
    if pgrep -f "openclaw.*gateway" &>/dev/null; then
        pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    fi
    log_ok "OpenClaw gateway stopped"
else
    log_skip "Gateway was not running"
fi
rm -f "$LOG_DIR/openclaw-gateway.pid"

# --- Unload model from Ollama (free memory, keep server) ---
if curl_check http://localhost:11434/api/tags &>/dev/null; then
    log_run "Unloading model from memory..."
    curl_check http://localhost:11434/api/generate \
        -d "{\"model\":\"${OLLAMA_MODEL_NAME}\",\"keep_alive\":0}" \
        > /dev/null 2>&1 || true
    log_ok "Model '${OLLAMA_MODEL_NAME}' unloaded from memory"
    log_info "Ollama server left running (manages other models)"
    log_info "Full stop: ${CYN}systemctl stop ollama${RST} or ${CYN}pkill ollama${RST}"
else
    log_skip "Ollama server not running"
fi

echo ""
log_ok "Stack shut down. Memory freed."
echo ""
echo -e "  ${BOLD}Restart:${RST}  ${CYN}./start${RST}"
echo ""
