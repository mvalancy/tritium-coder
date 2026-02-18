#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  One-Click Installer
#  (c) 2026 Matthew Valancy  |  Valpatel Software
#
#  Designed for NVIDIA GB10 with 128GB unified memory.
#  Installs everything needed to run a local AI coding agent
#  with Claude Code. No internet required after install.
#
#  Default model: Qwen3-Coder-Next (80B MoE, ~50GB, full tool calling)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh"

# --- Parse arguments ---
REMOTE_MODE=false
for arg in "$@"; do
    case "$arg" in
        --remote) REMOTE_MODE=true ;;
        --help|-h)
            banner
            echo -e "  ${BOLD}./install.sh${RST} — Install the full Tritium Coder stack"
            echo ""
            echo -e "  Downloads and configures Ollama and the Claude Code proxy."
            echo -e "  Pulls the default model (~50 GB). Safe to re-run — already-installed"
            echo -e "  components are skipped."
            echo ""
            echo -e "  ${BOLD}Usage:${RST}  ./install.sh [--remote]"
            echo ""
            echo -e "  ${BOLD}Options:${RST}"
            echo -e "    ${CYN}--remote${RST}     Skip local model download; use a remote Ollama server"
            echo -e "                 Set ${BOLD}OLLAMA_HOST${RST} to the remote URL first."
            echo ""
            echo -e "  ${BOLD}Environment:${RST}"
            echo -e "    ${CYN}OLLAMA_HOST${RST}  Remote Ollama URL (e.g. http://100.x.x.x:11434)"
            echo -e "    ${CYN}QUANT${RST}        Quantization tag to append (e.g. QUANT=UD-TQ1_0)"
            echo ""
            echo -e "  ${BOLD}Requires:${RST}  Python 3 (must be pre-installed)"
            echo -e "  ${BOLD}May install:${RST}  Ollama, Node.js 22, pnpm, python3-venv, pip, git"
            echo ""
            echo -e "  ${BOLD}After install:${RST}"
            echo -e "    ${CYN}./start${RST}       Start the stack"
            echo -e "    ${CYN}./dashboard${RST}   Open control panel"
            echo -e "    ${CYN}./status${RST}      Check status"
            echo ""
            exit 0
            ;;
    esac
done

# --- Quantization tag ---
if [ -n "${QUANT:-}" ]; then
    OLLAMA_MODEL_NAME="${OLLAMA_MODEL_NAME}:${QUANT}"
fi

banner
tlog "--- install.sh started ---"

if [ "$REMOTE_MODE" = true ]; then
    echo -e "  ${DIM}Mode:  ${RST}${BOLD}Remote${RST}  ${DIM}(model served by ${OLLAMA_HOST:-\$OLLAMA_HOST not set})${RST}"
else
    echo -e "  ${DIM}Model: ${RST}${BOLD}${OLLAMA_MODEL_NAME}${RST}  ${DIM}(~50 GB download)${RST}"
fi
echo ""

ensure_dir "$LOG_DIR"
ensure_dir "$CONFIG_DIR"

# =========================================================================
#  PREFLIGHT: Hardware checks
# =========================================================================
section "Hardware Check"

HW_RAM=$(detect_ram_gb)
HW_GPU=$(detect_gpu_name)
HW_VRAM=$(detect_vram_mb)
HW_UNIFIED=$(detect_unified_memory)
HW_AVAIL=$(detect_available_memory_gb)
HW_TIER=$(detect_hw_tier)
HW_DISK=$(detect_disk_gb)

log_info "RAM:       ${BOLD}${HW_RAM} GB${RST}"
if [ -n "$HW_GPU" ]; then
    log_info "GPU:       ${BOLD}${HW_GPU}${RST}"
    log_info "VRAM:      ${BOLD}$(( HW_VRAM / 1024 )) GB${RST} ${DIM}(${HW_VRAM} MB)${RST}"
    if [ "$HW_UNIFIED" = "true" ]; then
        log_info "Memory:    ${BOLD}${HW_AVAIL} GB unified${RST}"
    else
        log_info "Memory:    ${BOLD}${HW_AVAIL} GB VRAM${RST} ${DIM}(discrete GPU)${RST}"
    fi
else
    log_info "GPU:       ${DIM}None detected (no nvidia-smi)${RST}"
    log_info "Memory:    ${BOLD}${HW_RAM} GB RAM only${RST}"
fi
log_info "Disk free: ${BOLD}${HW_DISK} GB${RST}"
log_info "Tier:      ${BOLD}${HW_TIER}${RST}"

# --- Disk space gate ---
if [ "$HW_DISK" -lt 60 ] 2>/dev/null; then
    echo ""
    log_fail "Not enough disk space."
    log_info "The model alone is ~50 GB. You have ${BOLD}${HW_DISK} GB${RST} free."
    log_info "Free up space or use ${CYN}--remote${RST} mode to skip the download."
    exit 1
elif [ "$HW_DISK" -lt 80 ] 2>/dev/null && [ "$REMOTE_MODE" = false ]; then
    echo ""
    log_warn "Disk space is tight (${HW_DISK} GB free). The model is ~50 GB."
    if ! ask_yn "Continue anyway?" "n"; then
        log_info "Aborted. Free up disk space or use ${CYN}./install.sh --remote${RST}."
        exit 0
    fi
fi

# --- Memory/GPU gate (skip if remote mode) ---
if [ "$REMOTE_MODE" = false ]; then
    case "$HW_TIER" in
        insufficient)
            echo ""
            echo -e "  ${BRED}+--------------------------------------------------------------+"
            echo -e "  |  Hardware does not meet minimum requirements                 |"
            echo -e "  +--------------------------------------------------------------+${RST}"
            echo ""
            log_fail "Available memory: ${BOLD}${HW_AVAIL} GB${RST} — need at least 16 GB GPU memory."
            echo ""
            log_info "The default model (${OLLAMA_MODEL_NAME}) requires ~50 GB and won't fit."
            echo ""
            log_info "${BOLD}Options:${RST}"
            log_info "  1. ${CYN}Remote mode${RST} — offload inference to a GPU server over Tailscale:"
            log_info "     ${BOLD}OLLAMA_HOST=http://<gpu-server>:11434 ./install.sh --remote${RST}"
            log_info "  2. ${CYN}Smaller quant${RST} — use a heavily quantized model (lower quality):"
            log_info "     ${BOLD}QUANT=UD-TQ1_0 ./install.sh${RST}"
            echo ""
            if ! ask_yn "Install anyway? (model download will likely fail)" "n"; then
                exit 0
            fi
            ;;
        low)
            echo ""
            log_warn "Available memory: ${BOLD}${HW_AVAIL} GB${RST} — the default model (~50 GB) won't fit."
            echo ""
            log_info "${BOLD}Options:${RST}"
            log_info "  1. ${CYN}Remote mode${RST} — offload inference to a GPU server:"
            log_info "     ${BOLD}OLLAMA_HOST=http://<gpu-server>:11434 ./install.sh --remote${RST}"
            log_info "  2. ${CYN}Smaller quant${RST} — try a quantized model:"
            log_info "     ${BOLD}QUANT=UD-TQ1_0 ./install.sh${RST}"
            log_info "  3. ${CYN}Mesh node${RST} — join another machine's agent mesh"
            echo ""
            if ! ask_yn "Install anyway?" "n"; then
                exit 0
            fi
            ;;
        mid)
            echo ""
            log_warn "Available memory: ${BOLD}${HW_AVAIL} GB${RST} — model will fit but it'll be tight."
            log_info "Consider adding this machine as a mesh node for a larger setup."
            echo ""
            if ! ask_yn "Continue?" "y"; then
                exit 0
            fi
            ;;
        full)
            echo ""
            log_ok "Hardware looks good — ${BOLD}${HW_AVAIL} GB${RST} available"
            ;;
    esac
fi

# =========================================================================
#  PREFLIGHT: Check what's installed and what's missing
# =========================================================================
section "Checking Requirements"

NEED_SUDO=false
MISSING_APT=()
NEED_OLLAMA=false
NEED_NODE=false
HAS_PYTHON=false

# --- Python 3 (hard requirement, can't auto-install reliably) ---
if require_cmd python3; then
    PY_VER=$(python3 --version 2>/dev/null | awk '{print $2}')
    log_ok "Python ${DIM}v${PY_VER}${RST}"
    HAS_PYTHON=true
else
    log_fail "Python 3 ${RED}not found${RST}"
fi

# --- python3-venv ---
if [ "$HAS_PYTHON" = true ] && python3 -m venv --help &>/dev/null; then
    log_ok "Python venv module"
else
    if [ "$HAS_PYTHON" = true ]; then
        log_warn "python3-venv ${YLW}not installed${RST}"
        MISSING_APT+=("python3-venv")
        NEED_SUDO=true
    fi
fi

# --- pip ---
if [ "$HAS_PYTHON" = true ] && python3 -m pip --version &>/dev/null; then
    log_ok "pip"
else
    if [ "$HAS_PYTHON" = true ]; then
        log_warn "pip ${YLW}not installed${RST}"
        MISSING_APT+=("python3-pip")
        NEED_SUDO=true
    fi
fi

# --- Git ---
if require_cmd git; then
    log_ok "Git"
else
    log_warn "Git ${YLW}not installed${RST}"
    MISSING_APT+=("git")
    NEED_SUDO=true
fi

# --- Ollama ---
if require_cmd ollama; then
    OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
    log_ok "Ollama ${DIM}v${OLLAMA_VER}${RST}"
else
    log_warn "Ollama ${YLW}not installed${RST}"
    NEED_OLLAMA=true
    NEED_SUDO=true
fi

# --- Node.js (optional, for Claude Code CLI) ---
NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$NODE_VERSION" -gt 0 ] 2>/dev/null; then
    log_ok "Node.js ${DIM}v$(node --version 2>/dev/null)${RST}"
else
    log_info "Node.js ${DIM}not installed (needed for Claude Code CLI)${RST}"
fi

# --- Claude Code CLI ---
if require_cmd claude; then
    log_ok "Claude Code CLI"
else
    log_info "Claude Code CLI ${DIM}not installed (optional, install later with: npm i -g @anthropic-ai/claude-code)${RST}"
fi

# =========================================================================
#  STOP if Python is missing — can't auto-install this reliably
# =========================================================================
if [ "$HAS_PYTHON" = false ]; then
    echo ""
    log_fail "Python 3 is required and must be installed manually."
    log_info "  Ubuntu/Debian:  ${BOLD}sudo apt install python3 python3-pip python3-venv${RST}"
    log_info "  Then re-run:    ${BOLD}./install.sh${RST}"
    exit 1
fi

# =========================================================================
#  ASK before proceeding if sudo is needed
# =========================================================================
if [ "$NEED_SUDO" = true ]; then
    section "Installation Plan"

    log_info "The following will be installed:"
    [ "$NEED_OLLAMA" = true ] && log_info "  ${BOLD}Ollama${RST}          ${DIM}Model server (curl installer, uses sudo)${RST}"
    [ ${#MISSING_APT[@]} -gt 0 ] && log_info "  ${BOLD}${MISSING_APT[*]}${RST}  ${DIM}(apt-get)${RST}"
    echo ""

    # Check if sudo is available at all
    if ! command -v sudo &>/dev/null; then
        log_fail "sudo is not available on this system."
        log_info "Install the packages listed above manually, then re-run this script."
        exit 1
    fi

    if ! ask_yn "Proceed?"; then
        log_info "Aborted. Install the packages above manually, then re-run."
        exit 0
    fi

    # Verify sudo actually works (this prompts for password once)
    if ! sudo true; then
        log_fail "Could not get sudo access."
        exit 1
    fi
fi

# =========================================================================
#  PHASE 1: Install missing system dependencies
# =========================================================================
section "Phase 1/3 : System Dependencies"

# --- apt packages ---
if [ ${#MISSING_APT[@]} -gt 0 ]; then
    log_run "Updating package lists..."
    sudo apt-get update -qq >> "$LOG_DIR/deps-install.log" 2>&1
    log_run "Installing ${MISSING_APT[*]}..."
    sudo apt-get install -y "${MISSING_APT[@]}" >> "$LOG_DIR/deps-install.log" 2>&1
    log_ok "Installed ${MISSING_APT[*]}"
fi

# --- Ollama ---
if [ "$NEED_OLLAMA" = true ]; then
    log_run "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sudo sh
    if require_cmd ollama; then
        log_ok "Ollama installed"
    else
        log_fail "Ollama installation failed."
        exit 1
    fi
else
    log_ok "Ollama"
fi

# --- Node.js 22 ---
if [ "$NEED_NODE" = true ]; then
    log_run "Installing Node.js 22 via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >> "$LOG_DIR/node-install.log" 2>&1
    sudo apt-get install -y nodejs >> "$LOG_DIR/node-install.log" 2>&1
    NEW_NODE=$(node --version 2>/dev/null || echo "unknown")
    log_ok "Node.js ${DIM}${NEW_NODE}${RST}"
    NODE_VERSION=$(echo "$NEW_NODE" | sed 's/v//' | cut -d. -f1 || echo "0")
else
    log_ok "Node.js"
fi

log_ok "All dependencies ready"

# =========================================================================
#  PHASE 2: Download & Install Model via Ollama
# =========================================================================

if [ "$REMOTE_MODE" = true ]; then
    section "Phase 2/3 : Remote Ollama Setup"

    OLLAMA_URL=$(get_ollama_url)
    if [ "$OLLAMA_URL" = "http://localhost:11434" ] && [ -z "${OLLAMA_HOST:-}" ]; then
        log_fail "Remote mode requires OLLAMA_HOST to be set."
        log_info "Example: ${BOLD}OLLAMA_HOST=http://100.x.x.x:11434 ./install.sh --remote${RST}"
        exit 1
    fi

    log_run "Checking remote Ollama at ${OLLAMA_URL}..."
    if curl_check "$OLLAMA_URL/api/tags" &>/dev/null; then
        log_ok "Remote Ollama is reachable at ${OLLAMA_URL}"
    else
        log_fail "Cannot reach Ollama at ${OLLAMA_URL}"
        log_info "Make sure Ollama is running on the remote machine and the URL is correct."
        exit 1
    fi

    log_ok "Skipping local model download (remote mode)"
else
    section "Phase 2/3 : Download Model (${OLLAMA_MODEL_NAME})"

    # Ensure Ollama is running
    if ! curl_check http://localhost:11434/api/tags &>/dev/null; then
        log_run "Starting Ollama server..."
        ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
        sleep 3
        if curl_check http://localhost:11434/api/tags &>/dev/null; then
            log_ok "Ollama server started"
        else
            log_fail "Could not start Ollama server. Check $LOG_DIR/ollama.log"
            exit 1
        fi
    else
        log_ok "Ollama server running"
    fi

    # Pull model (Ollama handles download, caching, and resume)
    if ollama_has_model "$OLLAMA_MODEL_NAME"; then
        MODEL_SIZE=$(ollama_model_size "$OLLAMA_MODEL_NAME")
        log_ok "Model '${OLLAMA_MODEL_NAME}' already installed ${DIM}(${MODEL_SIZE})${RST}"
    else
        timer_start
        log_run "Pulling ${OLLAMA_MODEL_NAME} from Ollama registry..."
        log_info "This is a ~50 GB download. Progress will appear below."
        log_info "The download resumes if interrupted."
        echo ""
        ollama pull "$OLLAMA_MODEL_NAME" 2>&1 | while IFS= read -r line; do
            echo -e "         ${DIM}${line}${RST}"
        done

        if ollama_has_model "$OLLAMA_MODEL_NAME"; then
            MODEL_SIZE=$(ollama_model_size "$OLLAMA_MODEL_NAME")
            log_ok "Model installed ${DIM}(${MODEL_SIZE}, $(timer_elapsed)s)${RST}"
        else
            log_fail "Failed to pull model '${OLLAMA_MODEL_NAME}'"
            exit 1
        fi
    fi
fi

# =========================================================================
#  PHASE 3: Claude Code Proxy
# =========================================================================
section "Phase 3/3 : Claude Code Proxy"

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

# Write proxy .env (use remote URL if in remote mode)
OLLAMA_URL=$(get_ollama_url)
cat > "$PROXY_DIR/.env" <<ENVEOF
OPENAI_API_KEY=ollama-local
OPENAI_BASE_URL=${OLLAMA_URL}/v1
BIG_MODEL=${OLLAMA_MODEL_NAME}
MIDDLE_MODEL=${OLLAMA_MODEL_NAME}
SMALL_MODEL=${OLLAMA_MODEL_NAME}
HOST=0.0.0.0
PORT=${PROXY_PORT}
ENVEOF
log_ok "Proxy configured ${DIM}(port ${PROXY_PORT}, Ollama at ${OLLAMA_URL})${RST}"

# =========================================================================
#  Playwright (headless browser for vision gate screenshots)
# =========================================================================
section "Playwright"
if python3 -c "from playwright.sync_api import sync_playwright" 2>/dev/null; then
    log_ok "Playwright already installed"
else
    log_run "Installing Playwright (headless browser for screenshots)..."
    pip install --user --break-system-packages playwright 2>/dev/null \
        || pip install --user playwright 2>/dev/null \
        || pip install playwright 2>/dev/null \
        || { log_warn "Could not install Playwright — vision gate will be disabled"; true; }
    if python3 -c "import playwright" 2>/dev/null; then
        python3 -m playwright install chromium 2>/dev/null \
            && log_ok "Playwright + Chromium installed" \
            || log_warn "Playwright installed but Chromium browser failed"
    fi
fi

# =========================================================================
#  Persist remote config
# =========================================================================
if [ "$REMOTE_MODE" = true ] && [ -n "${OLLAMA_HOST:-}" ]; then
    echo "OLLAMA_HOST=${OLLAMA_HOST}" > "$PROJECT_DIR/.tritium.env"
    log_ok "Saved OLLAMA_HOST to .tritium.env"
fi

# =========================================================================
#  DONE
# =========================================================================
tlog "--- install.sh finished ---"
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
echo -e "  |${RST}  ${BGRN}Installation Complete!${RST}                                      ${BMAG}|"
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""
echo -e "  ${BOLD}Model:${RST}     ${OLLAMA_MODEL_NAME}"
echo -e "  ${BOLD}Features:${RST}  Tool calling, code generation, debugging"
echo ""
echo -e "  ${BOLD}Quick Start:${RST}"
echo -e "    ${CYN}./start${RST}               Start the full stack (Ollama + proxy)"
echo -e "    ${CYN}./dashboard${RST}           Open control panel"
echo -e "    ${CYN}scripts/run-claude.sh${RST}  Launch Claude Code (local)"
echo -e "    ${CYN}./iterate \"...\"${RST}        Build a project from a description"
echo -e "    ${CYN}./stop${RST}                Stop everything"
echo -e "    ${CYN}./status${RST}              Check stack status"
echo ""
