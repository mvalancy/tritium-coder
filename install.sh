#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  One-Click Installer
#  (c) 2026 Matthew Valancy  |  Valpatel Software
#
#  Designed for NVIDIA GB10 with 128GB unified memory.
#  Installs everything needed to run a local AI coding agent
#  with Claude Code and OpenClaw. No internet required after install.
#
#  Default model: Qwen3-Coder-Next (80B MoE, ~50GB, full tool calling)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh"

banner

echo -e "  ${DIM}Model: ${RST}${BOLD}${OLLAMA_MODEL_NAME}${RST}  ${DIM}(~50 GB download)${RST}"
echo ""

ensure_dir "$MODEL_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$CONFIG_DIR"

# =========================================================================
#  PHASE 1: System Dependencies
# =========================================================================
section "Phase 1/4 : System Dependencies"

# --- Ollama ---
if require_cmd ollama; then
    OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
    log_ok "Ollama ${DIM}v${OLLAMA_VER}${RST}"
else
    log_run "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_DIR/ollama-install.log" 2>&1
    if require_cmd ollama; then
        log_ok "Ollama installed"
    else
        log_fail "Ollama installation failed. See $LOG_DIR/ollama-install.log"
        exit 1
    fi
fi

# --- Python 3 ---
if require_cmd python3; then
    PY_VER=$(python3 --version 2>/dev/null | awk '{print $2}')
    log_ok "Python ${DIM}v${PY_VER}${RST}"
else
    log_fail "Python 3 is required but not found."
    log_info "Install: sudo apt install python3 python3-pip python3-venv"
    exit 1
fi

# --- python3-venv (needed for venv creation) ---
if python3 -m venv --help &>/dev/null; then
    log_ok "Python venv module"
else
    log_run "Installing python3-venv..."
    sudo apt-get install -y python3-venv >> "$LOG_DIR/deps-install.log" 2>&1
    log_ok "Python venv module installed"
fi

# --- pip ---
if python3 -m pip --version &>/dev/null; then
    log_ok "pip"
else
    log_run "Installing pip..."
    sudo apt-get install -y python3-pip >> "$LOG_DIR/deps-install.log" 2>&1
    log_ok "pip installed"
fi

# --- Git ---
if require_cmd git; then
    log_ok "Git"
else
    log_run "Installing git..."
    sudo apt-get install -y git >> "$LOG_DIR/deps-install.log" 2>&1
    log_ok "Git installed"
fi

# --- Node.js (>= 22 for OpenClaw) ---
NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$NODE_VERSION" -ge 22 ] 2>/dev/null; then
    log_ok "Node.js ${DIM}v$(node --version 2>/dev/null)${RST}"
else
    log_warn "Node.js v${NODE_VERSION} found, but OpenClaw requires v22+"
    if ask_yn "Install Node.js 22 via NodeSource?"; then
        log_run "Adding NodeSource repo and installing Node.js 22..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >> "$LOG_DIR/node-install.log" 2>&1
        sudo apt-get install -y nodejs >> "$LOG_DIR/node-install.log" 2>&1
        NEW_NODE=$(node --version 2>/dev/null || echo "unknown")
        log_ok "Node.js upgraded to ${DIM}${NEW_NODE}${RST}"
    else
        log_warn "Skipping Node.js upgrade. OpenClaw will not work without Node >= 22."
        log_info "Claude Code local mode will still work fine."
    fi
fi

# --- Claude Code CLI ---
if require_cmd claude; then
    log_ok "Claude Code CLI"
else
    log_warn "Claude Code CLI not found."
    log_info "Install: npm install -g @anthropic-ai/claude-code"
    log_info "Continuing without it (you can install later)."
fi

# =========================================================================
#  PHASE 2: Download & Install Model via Ollama
# =========================================================================
section "Phase 2/4 : Download Model (${OLLAMA_MODEL_NAME})"

# Ensure Ollama is running
if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
    log_run "Starting Ollama server..."
    ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
    sleep 3
    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        log_ok "Ollama server started"
    else
        log_fail "Could not start Ollama server. Check $LOG_DIR/ollama.log"
        exit 1
    fi
else
    log_ok "Ollama server running"
fi

# Pull model (Ollama handles download, caching, and resume)
if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
    MODEL_SIZE=$(ollama list 2>/dev/null | grep "$OLLAMA_MODEL_NAME" | awk '{print $3, $4}')
    log_ok "Model '${OLLAMA_MODEL_NAME}' already installed ${DIM}(${MODEL_SIZE})${RST}"
else
    log_run "Pulling ${OLLAMA_MODEL_NAME} from Ollama registry..."
    log_info "This is a ~50 GB download. Progress will appear below."
    log_info "The download resumes if interrupted."
    echo ""
    ollama pull "$OLLAMA_MODEL_NAME" 2>&1 | while IFS= read -r line; do
        echo -e "         ${DIM}${line}${RST}"
    done

    if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
        MODEL_SIZE=$(ollama list 2>/dev/null | grep "$OLLAMA_MODEL_NAME" | awk '{print $3, $4}')
        log_ok "Model installed ${DIM}(${MODEL_SIZE})${RST}"
    else
        log_fail "Failed to pull model '${OLLAMA_MODEL_NAME}'"
        exit 1
    fi
fi

# =========================================================================
#  PHASE 4: Claude Code Proxy
# =========================================================================
section "Phase 3/4 : Claude Code Proxy"

if [ -d "$PROXY_DIR" ] && [ -f "$PROXY_DIR/start_proxy.py" ]; then
    log_ok "Proxy already cloned"
else
    log_run "Cloning claude-code-proxy..."
    rm -rf "$PROXY_DIR"
    git clone --depth 1 https://github.com/fuergaosi233/claude-code-proxy.git "$PROXY_DIR" \
        >> "$LOG_DIR/proxy-install.log" 2>&1
    log_ok "Proxy cloned"
fi

# Set up venv
if [ ! -d "$PROXY_DIR/.venv" ]; then
    log_run "Creating Python venv for proxy..."
    python3 -m venv "$PROXY_DIR/.venv"
    log_ok "Venv created"
fi

log_run "Installing proxy dependencies..."
(
    source "$PROXY_DIR/.venv/bin/activate"
    pip install -q -r "$PROXY_DIR/requirements.txt" 2>&1
    deactivate
) >> "$LOG_DIR/proxy-install.log" 2>&1
log_ok "Proxy dependencies installed"

# Write proxy .env
cat > "$PROXY_DIR/.env" <<ENVEOF
OPENAI_API_KEY=ollama-local
OPENAI_BASE_URL=http://localhost:11434/v1
BIG_MODEL=${OLLAMA_MODEL_NAME}
MIDDLE_MODEL=${OLLAMA_MODEL_NAME}
SMALL_MODEL=${OLLAMA_MODEL_NAME}
HOST=0.0.0.0
PORT=${PROXY_PORT}
ENVEOF
log_ok "Proxy configured ${DIM}(port ${PROXY_PORT})${RST}"

# =========================================================================
#  PHASE 5: OpenClaw (cloned locally for reference + use)
# =========================================================================
section "Phase 4/4 : OpenClaw"

OPENCLAW_DIR="$PROJECT_DIR/.openclaw"

NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$NODE_VERSION" -ge 22 ] 2>/dev/null; then
    log_ok "Node.js ${DIM}v$(node --version)${RST}"

    # --- pnpm (needed for OpenClaw build) ---
    if ! require_cmd pnpm; then
        log_run "Installing pnpm..."
        sudo npm install -g pnpm >> "$LOG_DIR/openclaw-install.log" 2>&1
        log_ok "pnpm installed"
    else
        log_ok "pnpm"
    fi

    # --- Clone OpenClaw repo ---
    if [ -d "$OPENCLAW_DIR/.git" ]; then
        log_ok "OpenClaw repo already cloned"
        log_info "$OPENCLAW_DIR"
    else
        log_run "Cloning OpenClaw repo..."
        rm -rf "$OPENCLAW_DIR"
        git clone https://github.com/openclaw/openclaw.git "$OPENCLAW_DIR" \
            >> "$LOG_DIR/openclaw-install.log" 2>&1
        log_ok "OpenClaw cloned to ${DIM}.openclaw/${RST}"
    fi

    # --- Install dependencies ---
    if [ ! -d "$OPENCLAW_DIR/node_modules" ]; then
        log_run "Installing OpenClaw dependencies (pnpm install)..."
        (cd "$OPENCLAW_DIR" && pnpm install) >> "$LOG_DIR/openclaw-install.log" 2>&1
        log_ok "Dependencies installed"
    else
        log_ok "Dependencies already installed"
    fi

    # --- Build from source ---
    if [ ! -d "$OPENCLAW_DIR/dist" ]; then
        log_run "Building OpenClaw from source..."
        (cd "$OPENCLAW_DIR" && pnpm build) >> "$LOG_DIR/openclaw-install.log" 2>&1
        if [ -d "$OPENCLAW_DIR/dist" ]; then
            log_ok "OpenClaw built successfully"
        else
            log_fail "OpenClaw build failed. See $LOG_DIR/openclaw-install.log"
        fi
    else
        log_ok "OpenClaw already built"
    fi

    # --- Link globally ---
    if ! require_cmd openclaw; then
        log_run "Linking OpenClaw globally..."
        (cd "$OPENCLAW_DIR" && sudo npm link) >> "$LOG_DIR/openclaw-install.log" 2>&1
    fi

    if require_cmd openclaw; then
        OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
        log_ok "OpenClaw ${DIM}${OC_VER}${RST} (from local source)"
    else
        log_warn "OpenClaw build succeeded but global link failed."
        log_info "You can run it directly: node .openclaw/scripts/run-node.mjs"
    fi

    # Apply hardened OpenClaw config
    if [ -f "$CONFIG_DIR/openclaw.json" ]; then
        mkdir -p "$HOME/.openclaw"
        cp "$CONFIG_DIR/openclaw.json" "$HOME/.openclaw/openclaw.json"
        log_ok "Hardened config applied to ${DIM}~/.openclaw/openclaw.json${RST}"
        log_info "Security: no browser, exec allowlist, local filesystem, loopback only"
    else
        log_warn "config/openclaw.json not found — skipping config"
    fi

    # Build the Control UI (web dashboard)
    if [ ! -f "$OPENCLAW_DIR/dist/control-ui/index.html" ]; then
        log_run "Building OpenClaw Control UI..."
        (cd "$OPENCLAW_DIR" && pnpm ui:build) >> "$LOG_DIR/openclaw-install.log" 2>&1
        if [ -f "$OPENCLAW_DIR/dist/control-ui/index.html" ]; then
            log_ok "Control UI built (access via: openclaw dashboard)"
        else
            log_warn "Control UI build failed (dashboard will not be available)"
        fi
    else
        log_ok "Control UI already built"
    fi
else
    log_warn "Node.js < 22 -- skipping OpenClaw"
    log_info "Install Node 22+, then re-run this script."
fi

# =========================================================================
#  DONE
# =========================================================================
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
echo -e "  |${RST}  ${BGRN}Installation Complete!${RST}                                      ${BMAG}|"
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""
echo -e "  ${BOLD}Model:${RST}     ${OLLAMA_MODEL_NAME}"
echo -e "  ${BOLD}Features:${RST}  Tool calling, code generation, debugging"
echo ""
echo -e "  ${BOLD}Quick Start:${RST}"
echo -e "    ${CYN}./start.sh${RST}            Start the full stack (Ollama + proxy + gateway)"
echo -e "    ${CYN}openclaw dashboard${RST}    Open web dashboard"
echo -e "    ${CYN}./run-openclaw.sh${RST}     Launch terminal agent"
echo -e "    ${CYN}./run-claude.sh${RST}       Launch Claude Code (local)"
echo -e "    ${CYN}./stop.sh${RST}             Stop everything"
echo -e "    ${CYN}./status.sh${RST}           Check stack status"
echo ""
