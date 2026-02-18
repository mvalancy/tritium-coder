#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Start Local AI Stack
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}./start${RST} — Start the full AI stack"
    echo ""
    echo -e "  Launches Ollama, loads the model, starts the Claude Code proxy,"
    echo -e "  and starts the OpenClaw gateway. Safe to run multiple times —"
    echo -e "  already-running services are skipped."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./start"
    echo ""
    echo -e "  ${BOLD}Services started:${RST}"
    echo -e "    Ollama          :11434   Model server"
    echo -e "    Proxy           :${PROXY_PORT}    Anthropic API bridge"
    echo -e "    Gateway         :${GATEWAY_PORT}  OpenClaw agent manager"
    echo ""
    echo -e "  ${BOLD}See also:${RST}  ./stop, ./status, ./dashboard"
    echo ""
    exit 0
fi

banner
echo -e "  ${DIM}Starting Ollama, proxy, and gateway. Loads ${OLLAMA_MODEL_NAME} into GPU memory.${RST}"
echo ""

section "Starting Local AI Stack"

ensure_dir "$LOG_DIR"

# --- 1. Ollama Server ---
if curl_check http://localhost:11434/api/tags &>/dev/null; then
    log_ok "Ollama server already running"
else
    log_run "Starting Ollama server..."
    ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
    for i in $(seq 1 15); do
        if curl_check http://localhost:11434/api/tags &>/dev/null; then
            break
        fi
        sleep 1
    done
    if curl_check http://localhost:11434/api/tags &>/dev/null; then
        log_ok "Ollama server started"
    else
        log_fail "Ollama server failed to start. Check $LOG_DIR/ollama.log"
        exit 1
    fi
fi

# --- 2. Verify model exists ---
if ollama_has_model "$OLLAMA_MODEL_NAME"; then
    log_ok "Model '${OLLAMA_MODEL_NAME}' available"
else
    log_fail "Model '${OLLAMA_MODEL_NAME}' not found in Ollama."
    log_info "Run ${CYN}./install.sh${RST} first to download and import the model."
    exit 1
fi

# --- 3. Warm up the model ---
log_run "Loading model into memory (may take 1-3 minutes)..."
ollama run "$OLLAMA_MODEL_NAME" "Respond with only: READY" > /tmp/.tritium-warmup 2>/dev/null &
WARMUP_PID=$!
spin "$WARMUP_PID" "Loading ${OLLAMA_MODEL_NAME} into GPU memory..."
wait "$WARMUP_PID" 2>/dev/null || true
RESPONSE=$(cat /tmp/.tritium-warmup 2>/dev/null || echo "")
rm -f /tmp/.tritium-warmup
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
        log_fail "Proxy not installed. Run ${CYN}./install.sh${RST} first."
        exit 1
    fi
    if [ ! -d "$PROXY_DIR/.venv" ]; then
        log_fail "Proxy venv not set up. Run ${CYN}./install.sh${RST} first."
        exit 1
    fi

    log_run "Starting Claude Code proxy on port ${PROXY_PORT}..."
    (
        cd "$PROXY_DIR"
        source .venv/bin/activate
        nohup python start_proxy.py > "$LOG_DIR/proxy.log" 2>&1 &
        echo $! > "$LOG_DIR/proxy.pid"
    )

    for i in $(seq 1 10); do
        if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
            break
        fi
        sleep 1
    done

    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        log_ok "Proxy started on port ${PROXY_PORT}"
    else
        log_fail "Proxy failed to start. Check $LOG_DIR/proxy.log"
        exit 1
    fi
fi

# --- 5. OpenClaw Gateway ---
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    log_ok "OpenClaw gateway already running on port ${GATEWAY_PORT}"
else
    if command -v openclaw &>/dev/null; then
        GW_BIND=$(get_gateway_bind)

        # Apply hardened config if not present
        OC_CONFIG="$HOME/.openclaw/openclaw.json"
        if [ ! -f "$OC_CONFIG" ]; then
            mkdir -p "$HOME/.openclaw"
            sed -e "s/qwen3-coder-next/${OLLAMA_MODEL_NAME}/g" \
                -e "s/\"bind\": \"loopback\"/\"bind\": \"${GW_BIND}\"/" \
                "$CONFIG_DIR/openclaw.json" > "$OC_CONFIG"
        fi
        log_run "Starting OpenClaw gateway (bind ${GW_BIND})..."
        (
            cd "$PROJECT_DIR"
            nohup openclaw gateway run --bind "$GW_BIND" > "$LOG_DIR/openclaw-gateway.log" 2>&1 &
            echo $! > "$LOG_DIR/openclaw-gateway.pid"
        )

        for i in $(seq 1 8); do
            if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
                break
            fi
            sleep 1
        done

        if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
            log_ok "OpenClaw gateway started on port ${GATEWAY_PORT}"
        else
            log_warn "OpenClaw gateway may not have started. Check $LOG_DIR/openclaw-gateway.log"
        fi
    else
        log_warn "OpenClaw not installed (optional). Install: npm install -g openclaw@latest"
    fi
fi

# --- 6. Control Panel ---
if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} "; then
    log_ok "Control panel already running on port ${PANEL_PORT}"
else
    PANEL_DIR="$PROJECT_DIR/web"
    if [ -f "$PANEL_DIR/index.html" ]; then
        BIND_ADDR=$(get_bind_addr)
        log_run "Starting control panel on port ${PANEL_PORT}..."
        (
            cd "$PANEL_DIR"
            nohup python3 -m http.server "$PANEL_PORT" --bind "$BIND_ADDR" > "$LOG_DIR/panel.log" 2>&1 &
            echo $! > "$LOG_DIR/panel.pid"
        )
        sleep 1
        if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} "; then
            log_ok "Control panel started on port ${PANEL_PORT}"
        else
            log_warn "Control panel may not have started. Check $LOG_DIR/panel.log"
        fi
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
echo -e "    Chat Dashboard    ${BGRN}http://localhost:${GATEWAY_PORT}/#token=tritium-local-dev${RST}"
fi
if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} "; then
echo -e "    Control Panel     ${BGRN}http://localhost:${PANEL_PORT}${RST}"
fi
echo ""
echo -e "  ${BOLD}Next:${RST}"
echo -e "    ${CYN}scripts/run-claude.sh${RST}    Launch Claude Code (terminal)"
echo -e "    ${CYN}scripts/run-openclaw.sh${RST}  Launch OpenClaw agent (terminal)"
echo -e "    ${CYN}./dashboard${RST}              Open control panel"
echo -e "    ${CYN}openclaw dashboard${RST}       Open chat dashboard"
echo -e "    ${CYN}./status${RST}                 Check status"
echo -e "    ${CYN}./stop${RST}                   Stop everything"
echo ""
