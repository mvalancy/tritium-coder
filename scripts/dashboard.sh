#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Control Panel
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    banner
    echo -e "  ${BOLD}./dashboard${RST} — Open the web control panel"
    echo ""
    echo -e "  Starts the stack if needed, launches the control panel, and opens"
    echo -e "  your browser. Safe to run multiple times."
    echo ""
    echo -e "  ${BOLD}Usage:${RST}  ./dashboard [options]"
    echo ""
    echo -e "  ${BOLD}Options:${RST}"
    echo -e "    --no-browser    Start the panel without opening a browser"
    echo -e "    -h, --help      Show this help"
    echo ""
    echo -e "  ${BOLD}URL:${RST}    ${CYN}http://localhost:${PANEL_PORT}${RST}"
    echo -e "  ${BOLD}Stop:${RST}   ${CYN}./stop${RST} stops the panel along with everything else"
    echo ""
    exit 0
fi

banner

# Ensure the full stack is up (starts anything that's down)
ensure_stack

URL="http://localhost:${PANEL_PORT}"
echo ""
log_ok "Control panel: ${CYN}${URL}${RST}"

# Show Tailscale URL if available
if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null) || true
    if [ -n "${TS_STATUS:-}" ]; then
        TS_NAME=$(echo "$TS_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
        TS_ONLINE=$(echo "$TS_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online',False))" 2>/dev/null || echo "")
        if [ "$TS_ONLINE" = "True" ] && [ -n "$TS_NAME" ]; then
            log_ok "Remote: ${CYN}http://${TS_NAME}:${PANEL_PORT}${RST}"
        fi
    fi
fi
echo ""

# Try to open in browser (unless --no-browser)
if [[ "${1:-}" == "--no-browser" ]]; then
    log_info "Skipping browser (--no-browser)"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$URL" 2>/dev/null &
elif command -v open &>/dev/null; then
    open "$URL" 2>/dev/null &
else
    log_info "Open ${CYN}${URL}${RST} in your browser"
fi
