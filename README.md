# Tritium Coder

**Dead simple one-button local coder utilizing the shifting landscape of the best open source tools and models.**

Run a 229-billion parameter AI coding assistant on your own hardware. No cloud. No API keys. No data leaves your machine.

*By Matthew Valancy | Valpatel Software | (c) 2026*

---

## What Is This?

Tritium Coder turns a mini PC into a fully self-contained AI coding workstation. One script downloads a state-of-the-art open source model, wires it into professional coding tools, and gets out of your way.

**Current stack:**
- **Model:** [MiniMax-M2.5](https://huggingface.co/MiniMaxAI/MiniMax-M2.5) (229B MoE, quantized to fit your hardware)
- **Serving:** [Ollama](https://ollama.com) (local model server)
- **Coding interfaces:** [Claude Code](https://github.com/anthropics/claude-code) + [OpenClaw](https://github.com/openclaw/openclaw)
- **Glue:** [claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) (API translation layer)

Everything runs offline after the initial setup download.

## Minimum System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 96 GB unified/shared | 128 GB+ unified/shared |
| GPU | NVIDIA with 8 GB+ VRAM | NVIDIA with unified memory (GB10, Jetson) |
| Disk | 120 GB free | 200 GB+ free |
| OS | Linux (aarch64 or x86_64) | Ubuntu 24.04+ |
| CPU | 8 cores | 12+ cores |

### Tested Hardware

Tritium Coder is designed for prosumer and engineering mini PCs in the $3,000 - $20,000 range:

| Device | RAM | GPU | Price Range | Fit |
|--------|-----|-----|-------------|-----|
| **NVIDIA GB10** (Grace Blackwell) | 128 GB unified | Blackwell | ~$3,000 | Best value |
| **NVIDIA Jetson AGX Thor** | 128 GB unified | Thor | ~$5,000+ | Excellent |
| **Custom workstation** (RTX 5090 x2) | 128 GB+ | 2x 32 GB VRAM | $8,000-$15,000 | Great |
| **NVIDIA DGX Station** | 256 GB+ | Multiple GPUs | $15,000+ | Overkill but works |
| **Apple Mac Studio** (M4 Ultra) | 192 GB unified | Integrated | ~$8,000 | Use MLX quants instead |

## Quick Start

```bash
git clone https://github.com/mvalancy/tritium-coder.git
cd tritium-coder
./install.sh
```

That's it. The installer handles everything:

1. Checks and installs system dependencies (Ollama, Python, Node.js, Git)
2. Downloads the quantized model from HuggingFace (~83 GB for default Q2_K_L)
3. Imports the model into Ollama
4. Sets up the Claude Code translation proxy
5. Installs and configures OpenClaw

### After install:

```bash
./start.sh          # Start the local AI stack
./run-claude.sh     # Code with Claude Code (offline)
./run-openclaw.sh   # Code with OpenClaw (offline)
./stop.sh           # Stop and free memory
./status.sh         # Check what's running
```

## Architecture

```
 You
  |
  |--- ./run-claude.sh ----> Claude Code CLI
  |                              |
  |                         (Anthropic API)
  |                              |
  |                       claude-code-proxy :8082
  |                         (translates to OpenAI API)
  |                              |
  |--- ./run-openclaw.sh -> OpenClaw ----+
                                         |
                                    (OpenAI API)
                                         |
                                   Ollama :11434
                                         |
                                MiniMax-M2.5 (GGUF)
                                  quantized to fit
```

## Choosing a Quantization

Pick a quantization that fits your RAM. The installer defaults to `Q2_K_L` which works well on 128 GB systems.

```bash
QUANT=UD-IQ3_XXS ./install.sh   # Better quality, needs more RAM
QUANT=UD-IQ2_M   ./install.sh   # Smaller footprint, lower quality
```

| Quantization | Download | RAM Needed | Quality | Best For |
|-------------|----------|------------|---------|----------|
| `UD-IQ2_M` | ~78 GB | ~96 GB | Good | 96 GB systems |
| `Q2_K_L` | ~83 GB | ~100 GB | Better (default) | 128 GB systems |
| `UD-IQ3_XXS` | ~93 GB | ~110 GB | Great | 128 GB+ with headroom |
| `UD-Q3_K_XL` | ~101 GB | ~120 GB | Best | 128 GB+ (tight fit) |
| `IQ4_XS` | ~122 GB | ~140 GB | Excellent | 192 GB+ systems |

## File Structure

```
tritium-coder/
  install.sh          # One-click installer (run this first)
  start.sh            # Start the AI stack
  stop.sh             # Stop and free memory
  run-claude.sh       # Launch Claude Code locally
  run-openclaw.sh     # Launch OpenClaw locally
  status.sh           # Check stack status
  README.md           # This file
  LICENSE             # MIT License
  .lib/
    common.sh         # Shared UI library
  config/
    Modelfile         # Ollama model definition (generated)
    openclaw.json     # OpenClaw local config (generated)
  models/             # Downloaded model files (~83 GB)
  logs/               # Runtime logs
  .proxy/             # Claude Code proxy (auto-cloned)
```

## How It Works

**Model serving:** Ollama loads the quantized GGUF and exposes an OpenAI-compatible API on `localhost:11434`. GPU layers are maximized for inference speed on unified memory systems.

**Claude Code:** Expects Anthropic's Messages API. The proxy on port 8082 translates between Anthropic and OpenAI formats. Environment variables redirect Claude Code to the local proxy with all telemetry disabled.

**OpenClaw:** Connects to Ollama natively via its Ollama provider. Zero-cost model configuration for fully local operation.

## Troubleshooting

### Out of memory / system freezes

Your quantization is too large. Stop and try a smaller one:

```bash
./stop.sh
QUANT=UD-IQ2_M ./install.sh
```

### Slow responses

This is a 229B parameter model. First tokens may take 10-30 seconds. Tips:
- Close other memory-heavy applications
- Use a smaller quantization
- Reduce context length: edit `config/Modelfile`, change `num_ctx` to `16384`

### Proxy won't start

```bash
ss -tlnp | grep 8082    # Check what's on the port
./stop.sh               # Clean stop
./start.sh              # Restart
```

### OpenClaw says "Node >= 22 required"

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### Model download interrupted

Re-run `./install.sh`. The download resumes from where it left off.

### Logs

```bash
tail -f logs/ollama.log      # Ollama server
tail -f logs/proxy.log       # Claude Code proxy
tail -f logs/download.log    # Model download
```

## Uninstall

```bash
./stop.sh
ollama rm minimax-m2.5-local
rm -rf ~/Code/tritium-coder     # or wherever you cloned it
```

## Project Philosophy

The AI coding landscape moves fast. New models drop every month. New tools appear every week. Tritium Coder is designed to ride that wave:

- **One button:** Clone, run install, start coding. No YAML configs, no Docker compose, no dependency hell.
- **Local first:** Your code stays on your machine. Period.
- **Swappable:** When a better model drops, change one line and re-run install.
- **Affordable:** A $3,000 mini PC runs a 229B parameter model. That was unthinkable two years ago.

## Credits

- [MiniMax-M2.5](https://huggingface.co/MiniMaxAI/MiniMax-M2.5) by MiniMaxAI
- [GGUF Quantizations](https://huggingface.co/unsloth/MiniMax-M2.5-GGUF) by Unsloth
- [Ollama](https://ollama.com)
- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
- [OpenClaw](https://github.com/openclaw/openclaw)
- [claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) by fuergaosi233

## License

MIT License. See [LICENSE](LICENSE).
