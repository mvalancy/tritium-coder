# Tritium Coder

**Dead simple local AI coding stack. One install. One command. Scale across your hardware mesh.**

Run AI coding agents on your own hardware — one machine or a fleet. No cloud. No API keys. No data leaves your network.

*By Matthew Valancy | Valpatel Software | (c) 2026*

---

## What Is This?

Tritium Coder turns local hardware into an AI coding workstation — and scales it into an agent mesh across multiple machines. One script downloads a state-of-the-art model, wires it into professional coding tools with a web dashboard, and gets out of your way. Add more machines to your Tailscale network and they join the mesh automatically.

**Three ways to interact:**

1. **Dashboard** — Web UI for chat, job management, exec approvals, and config (`openclaw dashboard`)
2. **Terminal agent** — Interactive CLI agent that reads, writes, runs, and debugs code (`./run-openclaw.sh`)
3. **Claude Code** — Drop-in replacement for Claude using your local model (`./run-claude.sh`)

**Current default stack (every piece is swappable):**

| Layer | Current Default | Swap With |
|-------|----------------|-----------|
| **Language Model** | [Qwen3-Coder-Next](https://ollama.com/library/qwen3-coder-next) (80B MoE, 3B active) | Any Ollama model with tool calling |
| **Model Server** | [Ollama](https://ollama.com) | vLLM, SGLang, llama.cpp, LM Studio |
| **Agent + Dashboard** | [OpenClaw](https://github.com/openclaw/openclaw) | Any OpenAI-compatible client |
| **Coding Agent** | [Claude Code](https://github.com/anthropics/claude-code) | Aider, Continue, Cursor, Cline |
| **API Bridge** | [claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) | LiteLLM, claude-adapter |

Every component talks through standard APIs (OpenAI-compatible or Anthropic-compatible). Swap any layer without touching the others. When a better model drops, change one variable and re-run install.

## Quick Start

```bash
git clone https://github.com/mvalancy/tritium-coder.git
cd tritium-coder
./install.sh
```

That's it. The installer handles everything:

1. Checks and installs system dependencies (Ollama, Python, Node.js, Git)
2. Downloads the coding model via Ollama (~50 GB for Qwen3-Coder-Next)
3. Sets up the Claude Code translation proxy
4. Installs and configures OpenClaw with hardened security

### After install:

```bash
./start.sh            # Start the full stack (Ollama + proxy + gateway)
openclaw dashboard    # Open the web dashboard (chat, config, approvals)
./run-openclaw.sh     # Launch terminal agent
./run-claude.sh       # Launch Claude Code with local model
./stop.sh             # Stop and free memory
./status.sh           # Check what's running
```

**See [USAGE.md](USAGE.md) for detailed workflows, examples, and tips.**

## Architecture

### Single Machine

```
 You ─── Browser ──────── OpenClaw Dashboard (localhost:18789)
  |                              |
  |─── ./run-openclaw.sh ─── OpenClaw Agent ──┐
  |                                            |
  |─── ./run-claude.sh ──── Claude Code CLI    |
  |                              |             |
  |                         (Anthropic API)    |
  |                              |             |
  |                        claude-code-proxy   |
  |                         (:8082)            |
  |                              |             |
  └──────────────────────── Ollama :11434 ─────┘
                                 |
                       Qwen3-Coder-Next (80B MoE)
                          full tool calling
```

### Agent Mesh (Tailscale)

Scale across multiple machines on your Tailscale network. The primary node runs the heavy thinking model and the OpenClaw gateway; mesh nodes run specialized models (vision, fast code, embeddings, etc). Each node just needs Ollama — no other setup required.

```
 ┌───────────────────────────────────────────────┐
 │  Primary Node                                 │
 │  GB10 / workstation / whatever is biggest     │
 │                                               │
 │  Ollama → Qwen3-Coder-Next (thinking model)  │
 │  OpenClaw Gateway + Dashboard                 │
 │  Claude Code proxy                            │
 └───────────────────┬───────────────────────────┘
                     │ Tailscale (private network)
        ┌────────────┼────────────┐
        │            │            │
 ┌──────┴──────┐ ┌───┴──────┐ ┌──┴────────────┐
 │ Mesh Node   │ │ Mesh Node│ │ Mesh Node ... │
 │ (GB10, Orin │ │ (Orin,   │ │ (RTX card,    │
 │  AGX, etc)  │ │  RTX)    │ │  Jetson, etc) │
 │ Ollama →    │ │ Ollama → │ │ Ollama →      │
 │ vision model│ │ fast code│ │ embeddings    │
 └─────────────┘ └──────────┘ └───────────────┘
```

**Add a mesh node to `config/openclaw.json`:**

```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://127.0.0.1:11434",
        "api": "ollama",
        "models": [{ "id": "qwen3-coder-next", "reasoning": true }]
      },
      "mesh-node-a": {
        "baseUrl": "http://<tailscale-ip-or-hostname>:11434",
        "api": "ollama",
        "models": [{ "id": "llava-next", "input": ["text", "image"] }]
      },
      "mesh-node-b": {
        "baseUrl": "http://<tailscale-ip-or-hostname>:11434",
        "api": "ollama",
        "models": [{ "id": "qwen2.5-coder:7b" }]
      }
    }
  }
}
```

**Setting up a new mesh node:**
```bash
# On any machine on your Tailnet:
curl -fsSL https://ollama.com/install.sh | sh
ollama pull <model-name>
# That's it. Add the provider entry on the primary node.
```

**Example mesh roles:**

| Role | Model | Hardware | Purpose |
|------|-------|----------|---------|
| Primary thinker | Qwen3-Coder-Next 80B | GB10 (128 GB) | Planning, complex code, debugging |
| Fast coder | Qwen2.5-Coder 7B | Orin AGX (64 GB) | Quick edits, completions, tests |
| Vision | LLaVA-Next | Any GPU | Screenshot analysis, UI review |
| Embeddings | nomic-embed-text | Any CPU | Code search, RAG |

## Why Qwen3-Coder-Next?

The default model was chosen because **it actually works as a coding agent.** Tool calling support through Ollama means it can read files, edit code, run commands, and debug — the full agentic loop.

| Model | Size | Tool Calling | Agent Mode | Speed |
|-------|------|-------------|------------|-------|
| **Qwen3-Coder-Next** (default) | ~50 GB | Yes | Full agent | Fast (3B active MoE) |
| Devstral-2 123B | ~75 GB | Yes | Full agent | Slower (dense) |
| GPT-OSS 120B | ~65 GB | Yes | Full agent | Fast (5.1B active MoE) |
| MiniMax-M2.5 229B | ~56 GB | No | Chat only | Slow |

To use a different model, edit `OLLAMA_MODEL_NAME` in `.lib/common.sh` and update `.proxy/.env`.

## Minimum System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 96 GB unified/shared | 128 GB+ unified/shared |
| GPU | NVIDIA with 8 GB+ VRAM | NVIDIA with unified memory (GB10, Jetson) |
| Disk | 120 GB free | 200 GB+ free |
| OS | Linux (aarch64 or x86_64) | Ubuntu 24.04+ |
| CPU | 8 cores | 12+ cores |

### Tested Hardware

| Device | RAM | Price Range | Fit |
|--------|-----|-------------|-----|
| **NVIDIA GB10** (Grace Blackwell) | 128 GB unified | ~$3,000 | Best value |
| **NVIDIA Jetson AGX Thor** | 128 GB unified | ~$5,000+ | Excellent |
| **Custom workstation** (RTX 5090 x2) | 128 GB+ | $8,000-$15,000 | Great |
| **Apple Mac Studio** (M4 Ultra) | 192 GB unified | ~$8,000 | Use MLX quants |

For multi-node setups, satellite machines can be much smaller (any machine that can run Ollama with your chosen model).

## Security

Tritium Coder is hardened for **local coding work only**:

- **Localhost-only gateway** — not exposed on the network by default
- **Token authentication** — all gateway access requires an auth token
- **Allowlist shell execution** — commands must be explicitly approved before running
- **No browser automation** — Playwright/Chrome automation is disabled
- **No elevated permissions** — no sudo, no root access
- **Web search enabled** — the agent can search docs for research, but cannot install software or modify the system
- **Tailscale Serve** — optional HTTPS remote access through your private Tailnet (not the open internet)

See [USAGE.md](USAGE.md#security-model) for the full security breakdown.

## File Structure

```
tritium-coder/
  install.sh          # One-click installer (run this first)
  start.sh            # Start the AI stack (Ollama + proxy + gateway)
  stop.sh             # Stop and free memory
  run-claude.sh       # Launch Claude Code locally
  run-openclaw.sh     # Launch OpenClaw agent locally
  status.sh           # Check stack status
  USAGE.md            # Practical workflows and examples
  README.md           # This file
  LICENSE             # MIT License
  .lib/
    common.sh         # Shared UI library
  config/
    openclaw.json     # OpenClaw hardened config
  logs/               # Runtime logs
  .proxy/             # Claude Code proxy (auto-cloned)
  .openclaw/          # OpenClaw (auto-cloned)
```

## Swapping Components

**Different model:**
```bash
# Edit .lib/common.sh: change OLLAMA_MODEL_NAME
# Edit .proxy/.env: change model slots
# Then:
ollama pull your-new-model
./start.sh
```

**Different coding agent:** Replace `run-claude.sh` with your agent's launch script. As long as it talks to an OpenAI-compatible or Anthropic-compatible endpoint, it works.

**Different model server:** Point the proxy's `OPENAI_BASE_URL` at your server. Ollama, vLLM, SGLang, LM Studio — they all speak OpenAI API.

**Add a satellite node:**
```bash
# On the satellite machine:
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llava-next   # or whatever model you need
# Then add the provider to config/openclaw.json on the main machine
```

## Troubleshooting

### Slow responses

Qwen3-Coder-Next is an 80B MoE model (only 3B active per token). If responses are still slow, close other memory-heavy applications.

### Proxy won't start

```bash
ss -tlnp | grep 8082    # Check what's on the port
./stop.sh               # Clean stop
./start.sh              # Restart
```

### Dashboard "requires secure context" error

The browser needs HTTPS or localhost. Make sure you're accessing `http://localhost:18789`, not an IP address. For remote access, set up Tailscale Serve:
```bash
tailscale serve 18789
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
tail -f logs/ollama.log                # Ollama server
tail -f logs/proxy.log                 # Claude Code proxy
tail -f logs/openclaw-gateway.log      # OpenClaw gateway
openclaw logs --follow                 # OpenClaw agent logs
```

## Uninstall

```bash
./stop.sh
ollama rm qwen3-coder-next
rm -rf ~/Code/tritium-coder
```

## Credits

- [Qwen3-Coder-Next](https://ollama.com/library/qwen3-coder-next) by Alibaba/Qwen
- [Ollama](https://ollama.com)
- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
- [OpenClaw](https://github.com/openclaw/openclaw)
- [claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) by fuergaosi233

## License

MIT License. See [LICENSE](LICENSE).
