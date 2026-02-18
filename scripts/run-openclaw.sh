#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Launch OpenClaw (Local Mode)
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}scripts/run-openclaw.sh${RST} — Launch OpenClaw agent with local model"
    echo ""
    echo -e "  Starts the OpenClaw coding agent connected to the local Ollama model."
    echo -e "  Runs fully offline with hardened security settings."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  scripts/run-openclaw.sh [message]"
    echo ""
    echo -e "  ${BOLD}Examples:${RST}"
    echo -e "    ${CYN}scripts/run-openclaw.sh${RST}                          Interactive session"
    echo -e "    ${CYN}scripts/run-openclaw.sh \"Build a Flask app in /tmp\"${RST}  One-shot task"
    echo ""
    echo -e "  ${BOLD}Requires:${RST}  Ollama running (${CYN}./start${RST}), OpenClaw installed"
    echo ""
    exit 0
fi

banner

# --- Preflight checks ---
if ! curl_check http://localhost:11434/api/tags &>/dev/null; then
    log_fail "Ollama is not running."
    log_info "Run ${CYN}./start${RST} first."
    exit 1
fi

if ! require_cmd openclaw; then
    log_fail "OpenClaw is not installed."
    NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
    if [ "$NODE_VER" -lt 22 ] 2>/dev/null; then
        log_info "OpenClaw requires Node >= 22. You have v${NODE_VER}."
        log_info "Upgrade Node first, then: ${CYN}npm install -g openclaw@latest${RST}"
    else
        log_info "Install: ${CYN}npm install -g openclaw@latest${RST}"
    fi
    exit 1
fi

log_ok "Ollama running"
log_ok "OpenClaw installed"

GW_BIND=$(get_gateway_bind)

# --- Apply hardened local-only config ---
OC_CONFIG="$HOME/.openclaw/openclaw.json"
if [ ! -f "$OC_CONFIG" ]; then
    log_run "Applying hardened local-only config to ~/.openclaw/openclaw.json"
    mkdir -p "$HOME/.openclaw"
    sed -e "s/qwen3-coder-next/${OLLAMA_MODEL_NAME}/g" \
        -e "s/\"bind\": \"loopback\"/\"bind\": \"${GW_BIND}\"/" \
        "$CONFIG_DIR/openclaw.json" > "$OC_CONFIG"
    log_ok "Hardened config applied"
else
    log_ok "Using config at ~/.openclaw/openclaw.json"
fi

echo ""
echo -e "  ${DIM}Connecting OpenClaw to local model...${RST}"
echo -e "  ${DIM}Model:  ollama/${OLLAMA_MODEL_NAME}${RST}"
echo -e "  ${DIM}Mode:   Fully offline -- no cloud APIs${RST}"
echo ""
echo -e "  ${BOLD}Security:${RST}"
echo -e "    ${BGRN}[OK]${RST}  Web search / fetch    ${DIM}enabled (research only)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Browser automation    ${DIM}disabled${RST}"
echo -e "    ${BGRN}[OK]${RST}  Shell execution       ${DIM}full (no sudo/elevated)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Filesystem access     ${DIM}local only (loopback)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Network access        ${DIM}localhost only${RST}"
echo -e "    ${BGRN}[OK]${RST}  Elevated permissions  ${DIM}disabled${RST}"
echo ""

# --- Start gateway in background if not already running ---
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    log_ok "OpenClaw gateway already running on port ${GATEWAY_PORT}"
else
    log_run "Starting OpenClaw gateway (bind ${GW_BIND})..."
    ensure_dir "$LOG_DIR"
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
        log_ok "Gateway started on port ${GATEWAY_PORT}"
    else
        log_warn "Gateway may not have started. Check $LOG_DIR/openclaw-gateway.log"
    fi
fi

# --- Launch OpenClaw agent ---
export OLLAMA_API_KEY="ollama-local"
export OPENCLAW_GATEWAY_TOKEN="tritium-local-dev"

if [ $# -gt 0 ]; then
    MSG="$*"
else
    MSG="Hello! I am ready to help you code. Ask me to write, review, or debug code for any project."
fi

exec openclaw agent \
    --local \
    --session-id "tritium-local" \
    --message "$MSG" \
    --thinking medium
