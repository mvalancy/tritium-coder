#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  One-Click Installer
#  (c) 2026 Matthew Valancy  |  Valpatel Software
#
#  Designed for NVIDIA GB10 with 128GB unified memory.
#  Installs everything needed to run MiniMax-M2.5 locally
#  with Claude Code and OpenClaw. No internet required after install.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.lib/common.sh"

# --- Quantization selection ---
# GB10 has ~119GB usable. Quant must leave room for KV cache + OS.
#
#   Q2_K_L      ~ 83 GB   (recommended - good headroom)
#   UD-IQ3_XXS  ~ 93 GB   (better quality, tighter fit)
#   UD-Q3_K_XL  ~101 GB   (best quality, very tight)
#   UD-IQ2_M    ~ 78 GB   (most headroom, lower quality)
#
QUANT="${QUANT:-Q2_K_L}"

banner

echo -e "  ${DIM}Quantization: ${RST}${BOLD}${QUANT}${RST}  ${DIM}(override: QUANT=UD-IQ3_XXS ./install.sh)${RST}"
echo ""

ensure_dir "$MODEL_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$CONFIG_DIR"

# =========================================================================
#  PHASE 1: System Dependencies
# =========================================================================
section "Phase 1/5 : System Dependencies"

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

# --- huggingface_hub Python package ---
if python3 -c "import huggingface_hub" &>/dev/null; then
    HF_VER=$(python3 -c "import huggingface_hub; print(huggingface_hub.__version__)")
    log_ok "huggingface_hub ${DIM}v${HF_VER}${RST}"
else
    log_run "Installing huggingface_hub..."
    pip3 install --user --break-system-packages "huggingface_hub[hf_xet]" >> "$LOG_DIR/deps-install.log" 2>&1 || \
    pip3 install --user "huggingface_hub[hf_xet]" >> "$LOG_DIR/deps-install.log" 2>&1
    if python3 -c "import huggingface_hub" &>/dev/null; then
        log_ok "huggingface_hub installed"
    else
        log_fail "huggingface_hub install failed. See $LOG_DIR/deps-install.log"
        exit 1
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
#  PHASE 2: Download MiniMax-M2.5 GGUF
# =========================================================================
section "Phase 2/5 : Download MiniMax-M2.5 (${QUANT})"

GGUF_DIR="$MODEL_DIR/MiniMax-M2.5-GGUF"

# Check if model files already exist
# For split GGUFs, look for the first part (-00001-of-); for single files, any .gguf
EXISTING_GGUF=$(find "$GGUF_DIR" -name "*${QUANT}*-00001-of-*.gguf" 2>/dev/null | head -1)
[ -z "$EXISTING_GGUF" ] && EXISTING_GGUF=$(find "$GGUF_DIR" -name "*${QUANT}*.gguf" 2>/dev/null | head -1)
if [ -n "$EXISTING_GGUF" ]; then
    # For split files, show total size of all parts
    GGUF_PARENT=$(dirname "$EXISTING_GGUF")
    GGUF_SIZE=$(du -sh "$GGUF_PARENT" 2>/dev/null | cut -f1)
    PART_COUNT=$(find "$GGUF_PARENT" -name "*.gguf" 2>/dev/null | wc -l)
    log_ok "Model already downloaded ${DIM}(${GGUF_SIZE}, ${PART_COUNT} part(s))${RST}"
    log_info "$EXISTING_GGUF"
    GGUF_FILE="$EXISTING_GGUF"
else
    log_run "Downloading from unsloth/MiniMax-M2.5-GGUF..."
    log_info "This is a large download (~83 GB for Q2_K_L). Be patient."
    log_info "Progress will appear below. You can also check:"
    log_info "  tail -f $LOG_DIR/download.log"
    echo ""

    python3 - "$GGUF_DIR" "$QUANT" "$LOG_DIR/download.log" <<'PYEOF'
import sys, os
from huggingface_hub import snapshot_download

local_dir = sys.argv[1]
quant = sys.argv[2]
log_file = sys.argv[3]

os.makedirs(local_dir, exist_ok=True)

print(f"  Downloading *{quant}* files to {local_dir} ...")
result = snapshot_download(
    repo_id="unsloth/MiniMax-M2.5-GGUF",
    allow_patterns=[f"*{quant}*"],
    local_dir=local_dir,
)
print(f"  Download complete: {result}")
PYEOF

    # For split GGUFs, find the first part; for single files, any .gguf
    GGUF_FILE=$(find "$GGUF_DIR" -name "*${QUANT}*-00001-of-*.gguf" 2>/dev/null | head -1)
    [ -z "$GGUF_FILE" ] && GGUF_FILE=$(find "$GGUF_DIR" -name "*${QUANT}*.gguf" 2>/dev/null | head -1)
    if [ -z "$GGUF_FILE" ]; then
        log_fail "Download completed but no .gguf file found for quant: ${QUANT}"
        log_info "Files in $GGUF_DIR:"
        find "$GGUF_DIR" -type f -name "*.gguf" 2>/dev/null || echo "    (empty)"
        exit 1
    fi

    GGUF_PARENT=$(dirname "$GGUF_FILE")
    GGUF_SIZE=$(du -sh "$GGUF_PARENT" 2>/dev/null | cut -f1)
    PART_COUNT=$(find "$GGUF_PARENT" -name "*.gguf" 2>/dev/null | wc -l)
    log_ok "Download complete ${DIM}(${GGUF_SIZE}, ${PART_COUNT} part(s))${RST}"
fi

# =========================================================================
#  PHASE 3: Create Ollama Model
# =========================================================================
section "Phase 3/5 : Create Ollama Model"

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

# Check if model already exists
if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
    log_ok "Ollama model '${OLLAMA_MODEL_NAME}' already exists"
    if ask_yn "Recreate it from the downloaded GGUF?" "n"; then
        ollama rm "$OLLAMA_MODEL_NAME" 2>/dev/null || true
    else
        log_skip "Keeping existing model"
    fi
fi

# Create model if it doesn't exist
if ! ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
    log_run "Building Modelfile..."

    cat > "$CONFIG_DIR/Modelfile" <<MFEOF
FROM $GGUF_FILE

PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 40
PARAMETER num_ctx 32768
PARAMETER num_gpu 99

SYSTEM "You are a helpful coding assistant. Your name is MiniMax-M2.5 and you are built by MiniMax. You excel at writing, reviewing, and debugging code."
MFEOF

    log_run "Importing model into Ollama (this takes a moment)..."
    ollama create "$OLLAMA_MODEL_NAME" -f "$CONFIG_DIR/Modelfile" 2>&1 | while IFS= read -r line; do
        echo -e "         ${DIM}${line}${RST}"
    done

    if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
        log_ok "Model '${OLLAMA_MODEL_NAME}' created"
    else
        log_fail "Failed to create Ollama model"
        exit 1
    fi
fi

# =========================================================================
#  PHASE 4: Claude Code Proxy
# =========================================================================
section "Phase 4/5 : Claude Code Proxy"

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
#  PHASE 5: OpenClaw
# =========================================================================
section "Phase 5/5 : OpenClaw"

NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$NODE_VERSION" -ge 22 ] 2>/dev/null; then
    if require_cmd openclaw; then
        OC_VER=$(openclaw --version 2>/dev/null || echo "installed")
        log_ok "OpenClaw ${DIM}(${OC_VER})${RST}"
    else
        log_run "Installing OpenClaw..."
        npm install -g openclaw@latest >> "$LOG_DIR/openclaw-install.log" 2>&1
        if require_cmd openclaw; then
            log_ok "OpenClaw installed"
        else
            log_fail "OpenClaw install failed. See $LOG_DIR/openclaw-install.log"
            log_info "You can install manually later: npm install -g openclaw@latest"
        fi
    fi

    # Write OpenClaw config
    cat > "$CONFIG_DIR/openclaw.json" <<'OCEOF'
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://127.0.0.1:11434",
        "apiKey": "ollama-local",
        "api": "ollama",
        "models": [
          {
            "id": "minimax-m2.5-local",
            "name": "MiniMax M2.5 Local",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 32768
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "ollama/minimax-m2.5-local" }
    }
  }
}
OCEOF
    log_ok "OpenClaw config written to ${DIM}config/openclaw.json${RST}"
else
    log_warn "Node.js < 22 -- skipping OpenClaw"
    log_info "Upgrade Node to 22+ and re-run to enable OpenClaw."
fi

# =========================================================================
#  DONE
# =========================================================================
echo ""
echo -e "  ${BMAG}+--------------------------------------------------------------+"
echo -e "  |${RST}  ${BGRN}Installation Complete!${RST}                                      ${BMAG}|"
echo -e "  +--------------------------------------------------------------+${RST}"
echo ""
echo -e "  ${BOLD}Model:${RST}     $GGUF_FILE"
echo -e "  ${BOLD}Ollama:${RST}    ${OLLAMA_MODEL_NAME}"
echo -e "  ${BOLD}Quant:${RST}     ${QUANT}"
echo ""
echo -e "  ${BOLD}Quick Start:${RST}"
echo -e "    ${CYN}./start.sh${RST}          Start the local AI stack"
echo -e "    ${CYN}./run-claude.sh${RST}     Code with Claude Code (local)"
echo -e "    ${CYN}./run-openclaw.sh${RST}   Code with OpenClaw (local)"
echo -e "    ${CYN}./stop.sh${RST}           Stop everything"
echo -e "    ${CYN}./status.sh${RST}         Check stack status"
echo ""
