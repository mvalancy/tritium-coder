#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Start Local AI Stack
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.lib/common.sh"

banner

section "Starting Local AI Stack"

ensure_dir "$LOG_DIR"

# --- 1. Ollama Server ---
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    log_ok "Ollama server already running"
else
    log_run "Starting Ollama server..."
    ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
    for i in $(seq 1 15); do
        if curl -s http://localhost:11434/api/tags &>/dev/null; then
            break
        fi
        sleep 1
    done
    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        log_ok "Ollama server started"
    else
        log_fail "Ollama server failed to start. Check $LOG_DIR/ollama.log"
        exit 1
    fi
fi

# --- 2. Verify model exists ---
if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
    log_ok "Model '${OLLAMA_MODEL_NAME}' available"
else
    log_fail "Model '${OLLAMA_MODEL_NAME}' not found in Ollama."
    log_info "Run ./install.sh first to download and import the model."
    exit 1
fi

# --- 3. Warm up the model ---
log_run "Loading model into memory (may take 1-3 minutes)..."
RESPONSE=$(ollama run "$OLLAMA_MODEL_NAME" "Respond with only: READY" 2>/dev/null | head -1)
if [ -n "$RESPONSE" ]; then
    log_ok "Model loaded and responding"
else
    log_warn "Model loaded but gave empty response (may still work)"
fi

# --- 4. Claude Code Proxy ---
if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
    log_ok "Proxy already running on port ${PROXY_PORT}"
else
    if [ ! -f "$PROXY_DIR/start_proxy.py" ]; then
        log_fail "Proxy not installed. Run ./install.sh first."
        exit 1
    fi

    log_run "Starting Claude Code proxy on port ${PROXY_PORT}..."
    (
        cd "$PROXY_DIR"
        source .venv/bin/activate
        nohup python start_proxy.py > "$LOG_DIR/proxy.log" 2>&1 &
        echo $! > "$LOG_DIR/proxy.pid"
    )
    sleep 3

    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        log_ok "Proxy started on port ${PROXY_PORT}"
    else
        log_fail "Proxy failed to start. Check $LOG_DIR/proxy.log"
        exit 1
    fi
fi

# --- 5. OpenClaw Gateway ---
GATEWAY_PORT=18789
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    log_ok "OpenClaw gateway already running on port ${GATEWAY_PORT}"
else
    if command -v openclaw &>/dev/null; then
        # Apply hardened config if not present
        OC_CONFIG="$HOME/.openclaw/openclaw.json"
        if [ ! -f "$OC_CONFIG" ]; then
            mkdir -p "$HOME/.openclaw"
            cp "$CONFIG_DIR/openclaw.json" "$OC_CONFIG"
        fi
        log_run "Starting OpenClaw gateway..."
        (
            cd "$PROJECT_DIR"
            nohup openclaw gateway run --bind loopback > "$LOG_DIR/openclaw-gateway.log" 2>&1 &
            echo $! > "$LOG_DIR/openclaw-gateway.pid"
        )
        sleep 4
        if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
            log_ok "OpenClaw gateway started on port ${GATEWAY_PORT}"
        else
            log_warn "OpenClaw gateway may not have started. Check $LOG_DIR/openclaw-gateway.log"
        fi
    else
        log_warn "OpenClaw not installed (optional). Install: npm install -g openclaw@latest"
    fi
fi

# --- Ready ---
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
echo -e "  |${RST}  ${BGRN}Stack is running!${RST}                                            ${BMAG}|"
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""
echo -e "  ${BOLD}Services:${RST}"
echo -e "    Ollama API        ${BGRN}http://localhost:11434${RST}"
echo -e "    Claude Code Proxy ${BGRN}http://localhost:${PROXY_PORT}${RST}"
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
echo -e "    OpenClaw Gateway  ${BGRN}http://localhost:${GATEWAY_PORT}${RST}"
echo -e "    Dashboard         ${BGRN}http://localhost:${GATEWAY_PORT}/#token=tritium-local-dev${RST}"
fi
echo ""
echo -e "  ${BOLD}Next:${RST}"
echo -e "    ${CYN}./run-claude.sh${RST}       Launch Claude Code (terminal)"
echo -e "    ${CYN}./run-openclaw.sh${RST}     Launch OpenClaw agent (terminal)"
echo -e "    ${CYN}openclaw dashboard${RST}    Open dashboard (browser)"
echo -e "    ${CYN}./status.sh${RST}           Check status"
echo -e "    ${CYN}./stop.sh${RST}             Stop everything"
echo ""
