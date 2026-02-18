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
    echo -e "  Launches Ollama, loads the model, and starts the Claude Code proxy."
    echo -e "  Safe to run multiple times — already-running services are skipped."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./start"
    echo ""
    echo -e "  ${BOLD}Services started:${RST}"
    echo -e "    Ollama          :11434   Model server"
    echo -e "    Proxy           :${PROXY_PORT}    Anthropic API bridge"
    echo ""
    echo -e "  ${BOLD}See also:${RST}  ./stop, ./status, ./dashboard"
    echo ""
    exit 0
fi

banner
echo -e "  ${DIM}Starting Ollama and proxy. Loads ${OLLAMA_MODEL_NAME} into GPU memory.${RST}"
echo ""

# --- Memory warning (skip if remote mode) ---
OLLAMA_URL=$(get_ollama_url)
if [ "$OLLAMA_URL" = "http://localhost:11434" ]; then
    HW_TIER=$(detect_hw_tier)
    HW_AVAIL=$(detect_available_memory_gb)
    if [ "$HW_TIER" = "insufficient" ] || [ "$HW_TIER" = "low" ]; then
        log_warn "Available GPU memory: ${BOLD}${HW_AVAIL} GB${RST} — model may not fit."
        log_info "Consider using remote mode: ${CYN}OLLAMA_HOST=http://<gpu-server>:11434 ./start${RST}"
        echo ""
        if ! ask_yn "Start anyway?" "n"; then
            exit 0
        fi
    fi
fi

section "Starting Local AI Stack"

ensure_stack

# --- Summary ---
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
echo -e "  |${RST}  ${BGRN}Stack is running!${RST}                                            ${BMAG}|"
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""
echo -e "  ${BOLD}Services:${RST}"
echo -e "    Ollama API        ${BGRN}http://localhost:11434${RST}"
echo -e "    Claude Code Proxy ${BGRN}http://localhost:${PROXY_PORT}${RST}"
if port_listening "$PANEL_PORT"; then
echo -e "    Control Panel     ${BGRN}http://localhost:${PANEL_PORT}${RST}"
fi
echo ""
echo -e "  ${BOLD}Next:${RST}"
echo -e "    ${CYN}scripts/run-claude.sh${RST}    Launch Claude Code (terminal)"
echo -e "    ${CYN}./iterate \"...\"${RST}          Build a project from a description"
echo -e "    ${CYN}./dashboard${RST}              Open control panel"
echo -e "    ${CYN}./status${RST}                 Check status"
echo -e "    ${CYN}./stop${RST}                   Stop everything"
echo ""
