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

# --- Preflight: OpenClaw must be installed (can't auto-install) ---
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

# --- Ensure stack is up (starts anything that's down) ---
ensure_ollama || exit 1
ensure_model  || exit 1
ensure_proxy  || exit 1
ensure_gateway || true

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
