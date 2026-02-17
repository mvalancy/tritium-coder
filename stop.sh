#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Stop Local AI Stack
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.lib/common.sh"

banner

section "Shutting Down"

# --- Stop proxy ---
if pgrep -f "start_proxy.py" &>/dev/null; then
    pkill -f "start_proxy.py" 2>/dev/null || true
    sleep 1
    if pgrep -f "start_proxy.py" &>/dev/null; then
        pkill -9 -f "start_proxy.py" 2>/dev/null || true
    fi
    log_ok "Claude Code proxy stopped"
elif [ -f "$LOG_DIR/proxy.pid" ]; then
    PID=$(cat "$LOG_DIR/proxy.pid")
    kill "$PID" 2>/dev/null && log_ok "Proxy stopped (pid $PID)" || log_skip "Proxy was not running"
    rm -f "$LOG_DIR/proxy.pid"
else
    log_skip "Proxy was not running"
fi

# --- Stop OpenClaw gateway ---
if [ -f "$LOG_DIR/openclaw-gateway.pid" ]; then
    PID=$(cat "$LOG_DIR/openclaw-gateway.pid")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null && log_ok "OpenClaw gateway stopped (pid $PID)" || log_skip "Gateway was not running"
    else
        log_skip "Gateway was not running"
    fi
    rm -f "$LOG_DIR/openclaw-gateway.pid"
elif pgrep -f "openclaw.*gateway" &>/dev/null; then
    pkill -f "openclaw.*gateway" 2>/dev/null || true
    log_ok "OpenClaw gateway stopped"
else
    log_skip "Gateway was not running"
fi

# --- Unload model from Ollama (free memory, keep server) ---
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    log_run "Unloading model from memory..."
    curl -s http://localhost:11434/api/generate \
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
