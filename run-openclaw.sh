#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Launch OpenClaw (Local Mode)
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.lib/common.sh"

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

# --- Apply config if not already set ---
if [ ! -f "$HOME/.openclaw/openclaw.json" ]; then
    log_run "Copying local model config to ~/.openclaw/openclaw.json"
    mkdir -p "$HOME/.openclaw"
    cp "$CONFIG_DIR/openclaw.json" "$HOME/.openclaw/openclaw.json"
    log_ok "Config applied"
else
    log_info "Using existing ~/.openclaw/openclaw.json"
    log_info "Local model config available at: config/openclaw.json"
fi

echo ""
echo -e "  ${DIM}Connecting OpenClaw to local MiniMax-M2.5...${RST}"
echo -e "  ${DIM}Model:  ollama/${OLLAMA_MODEL_NAME}${RST}"
echo -e "  ${DIM}Mode:   Fully offline -- no cloud APIs${RST}"
echo ""

# --- Launch OpenClaw ---
export OLLAMA_API_KEY="ollama-local"

exec openclaw agent \
    --message "${1:-Hello! I am ready to help you code.}" \
    --thinking medium
