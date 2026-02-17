#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
#  Tritium Coder  |  Stack Status
#  (c) 2026 Matthew Valancy  |  Valpatel Software
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.lib/common.sh"

banner

section "Service Status"

# --- Ollama Server ---
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    log_ok "Ollama server       ${BGRN}running${RST}  ${DIM}http://localhost:11434${RST}"
else
    log_fail "Ollama server       ${RED}stopped${RST}"
fi

# --- Model loaded ---
LOADED=$(curl -s http://localhost:11434/api/ps 2>/dev/null | grep -o "\"$OLLAMA_MODEL_NAME\"" || echo "")
if [ -n "$LOADED" ]; then
    log_ok "MiniMax-M2.5        ${BGRN}loaded${RST}   ${DIM}${OLLAMA_MODEL_NAME}${RST}"
else
    if ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL_NAME"; then
        log_warn "MiniMax-M2.5        ${YLW}available (not loaded)${RST}"
    else
        log_fail "MiniMax-M2.5        ${RED}not installed${RST}"
    fi
fi

# --- Proxy ---
if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
    log_ok "Claude Code proxy   ${BGRN}running${RST}  ${DIM}http://localhost:${PROXY_PORT}${RST}"
else
    log_fail "Claude Code proxy   ${RED}stopped${RST}"
fi

section "System Resources"

# --- Memory ---
TOTAL_MEM=$(free -g | awk '/^Mem:/ {print $2}')
USED_MEM=$(free -g | awk '/^Mem:/ {print $3}')
AVAIL_MEM=$(free -g | awk '/^Mem:/ {print $7}')
log_info "Memory: ${BOLD}${USED_MEM}G${RST}${DIM} used / ${AVAIL_MEM}G available / ${TOTAL_MEM}G total${RST}"

# --- Disk ---
DISK_AVAIL=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
DISK_USED=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $3}')
log_info "Disk:   ${BOLD}${DISK_USED}${RST}${DIM} used / ${DISK_AVAIL} available${RST}"

# --- GPU ---
GPU_INFO=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || echo "N/A")
log_info "GPU:    ${DIM}${GPU_INFO}${RST}"

section "Installed Components"

# Check each tool
for cmd_pair in "ollama:Ollama" "python3:Python" "node:Node.js" "claude:Claude Code CLI" "openclaw:OpenClaw" "git:Git"; do
    cmd="${cmd_pair%%:*}"
    name="${cmd_pair##*:}"
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        log_ok "${name}  ${DIM}${ver}${RST}"
    else
        log_fail "${name}  ${RED}not found${RST}"
    fi
done

# Check huggingface_hub Python package
HF_VER=$(python3 -c "import huggingface_hub; print(huggingface_hub.__version__)" 2>/dev/null)
if [ -n "$HF_VER" ]; then
    log_ok "huggingface_hub  ${DIM}v${HF_VER}${RST}"
else
    log_fail "huggingface_hub  ${RED}not installed${RST}"
fi

# Check GGUF model files
GGUF_FILES=$(find "$MODEL_DIR" -name "*.gguf" 2>/dev/null | wc -l)
if [ "$GGUF_FILES" -gt 0 ]; then
    GGUF_SIZE=$(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)
    log_ok "Model files  ${DIM}${GGUF_FILES} file(s), ${GGUF_SIZE}${RST}"
else
    log_fail "Model files  ${RED}not downloaded${RST}"
fi

echo ""
