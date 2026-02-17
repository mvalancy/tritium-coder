#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Launch Claude Code (Local Mode)
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

if ! ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
    log_fail "Claude Code proxy is not running on port ${PROXY_PORT}."
    log_info "Run ${CYN}./start.sh${RST} first."
    exit 1
fi

if ! require_cmd claude; then
    log_fail "Claude Code CLI not found."
    log_info "Install: ${CYN}npm install -g @anthropic-ai/claude-code${RST}"
    exit 1
fi

log_ok "Ollama running"
log_ok "Proxy running on port ${PROXY_PORT}"
log_ok "Claude Code CLI found"
echo ""

echo -e "  ${DIM}Connecting Claude Code to local Qwen3-Coder-Next...${RST}"
echo -e "  ${DIM}Model:  ${OLLAMA_MODEL_NAME}${RST}"
echo -e "  ${DIM}Proxy:  http://localhost:${PROXY_PORT}${RST}"
echo -e "  ${DIM}Mode:   Fully offline -- no Anthropic connection${RST}"
echo ""

# --- Launch Claude Code pointing at local proxy ---
export ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT}"
export ANTHROPIC_API_KEY="local-qwen3-coder-next"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ENABLE_TELEMETRY=0

exec claude "$@"
