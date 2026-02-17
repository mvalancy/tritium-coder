#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Launch OpenClaw (Local Mode)
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner

# --- Preflight checks ---
if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
    log_fail "Ollama is not running."
    log_info "Run ${CYN}./start.sh${RST} first."
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

# --- Apply hardened local-only config ---
OC_CONFIG="$HOME/.openclaw/openclaw.json"
if [ ! -f "$OC_CONFIG" ]; then
    log_run "Applying hardened local-only config to ~/.openclaw/openclaw.json"
    mkdir -p "$HOME/.openclaw"
    cp "$CONFIG_DIR/openclaw.json" "$OC_CONFIG"
    log_ok "Hardened config applied"
else
    # Check if it has our security settings
    if ! grep -q '"enabled": false' "$OC_CONFIG" 2>/dev/null || ! grep -q '"workspaceOnly": true' "$OC_CONFIG" 2>/dev/null; then
        log_warn "Existing config may not have security hardening."
        log_info "Our hardened config is at: ${CYN}config/openclaw.json${RST}"
        log_info "To apply: ${CYN}cp config/openclaw.json ~/.openclaw/openclaw.json${RST}"
    else
        log_ok "Using hardened config at ~/.openclaw/openclaw.json"
    fi
fi

echo ""
echo -e "  ${DIM}Connecting OpenClaw to local Qwen3-Coder-Next...${RST}"
echo -e "  ${DIM}Model:  ollama/${OLLAMA_MODEL_NAME}${RST}"
echo -e "  ${DIM}Mode:   Fully offline -- no cloud APIs${RST}"
echo ""
echo -e "  ${BOLD}Security:${RST}"
echo -e "    ${BGRN}[OK]${RST}  Web search / fetch    ${DIM}enabled (research only)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Browser automation    ${DIM}disabled${RST}"
echo -e "    ${BGRN}[OK]${RST}  Software installs     ${DIM}blocked (exec allowlist)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Filesystem access     ${DIM}local only (loopback)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Network access        ${DIM}localhost only (add tailscale serve for remote)${RST}"
echo -e "    ${BGRN}[OK]${RST}  Elevated permissions  ${DIM}disabled${RST}"
echo ""

# --- Start gateway in background if not already running ---
GATEWAY_PORT=18789
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    log_ok "OpenClaw gateway already running on port ${GATEWAY_PORT}"
else
    log_run "Starting OpenClaw gateway..."
    ensure_dir "$LOG_DIR"
    (
        cd "$PROJECT_DIR"
        nohup openclaw gateway run --bind loopback > "$LOG_DIR/openclaw-gateway.log" 2>&1 &
        echo $! > "$LOG_DIR/openclaw-gateway.pid"
    )
    sleep 4
    if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        log_ok "Gateway started on port ${GATEWAY_PORT}"
    else
        log_warn "Gateway may not have started. Check $LOG_DIR/openclaw-gateway.log"
    fi
fi

# --- Launch OpenClaw agent ---
export OLLAMA_API_KEY="ollama-local"
export OPENCLAW_GATEWAY_TOKEN="tritium-local-dev"

MSG="${1:-Hello! I am ready to help you code. Ask me to write, review, or debug code for any project.}"

exec openclaw agent \
    --local \
    --session-id "tritium-local" \
    --message "$MSG" \
    --thinking medium
