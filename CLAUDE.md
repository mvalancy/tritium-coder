# Tritium Coder — Project Context

This is a local AI coding stack that runs on NVIDIA hardware (GB10, Jetson, RTX workstations). It wires together Ollama, OpenClaw, and Claude Code into a single install.

## Repository Structure

```
tritium-coder/
  install.sh              # Top-level installer (run once)
  start, stop, status     # Top-level commands (thin wrappers)
  test                    # Run test suite
  dashboard               # Open control panel (localhost:18790)
  CLAUDE.md               # This file
  README.md               # Project overview
  LICENSE                 # MIT
  scripts/
    start.sh              # Start the full stack (Ollama + proxy + gateway)
    stop.sh               # Stop everything and free memory
    status.sh             # Check what's running
    run-claude.sh         # Launch Claude Code with local model
    run-openclaw.sh       # Launch OpenClaw agent
    lib/
      common.sh           # Shared bash library (colors, logging, paths)
  config/
    openclaw.json         # Hardened OpenClaw config template
  web/
    index.html            # Control panel UI (service status, model info, quick actions)
  tests/
    run-all.sh            # Test suite — sends real coding jobs to the agent
  docs/
    usage.md              # Detailed usage workflows and examples
    architecture.md       # System architecture with diagrams
    security.md           # Security model and hardening
    mesh.md               # Multi-node agent mesh setup
  .proxy/                 # Claude Code proxy (auto-cloned, gitignored)
  .openclaw/              # OpenClaw source (auto-cloned, gitignored)
  logs/                   # Runtime logs (gitignored)
```

## Key Design Decisions

- **Single model variable**: `OLLAMA_MODEL_NAME` in `scripts/lib/common.sh` controls which model the entire stack uses. Change it there + `.proxy/.env` to swap models.
- **Full exec mode**: OpenClaw runs in `security: "full"` mode. The agent can run any command, but cannot sudo or use elevated permissions.
- **Loopback binding**: The gateway only listens on localhost. For remote access, use Tailscale Serve (HTTPS).
- **Token auth**: Gateway requires `tritium-local-dev` token. This is a local default — not a secret since it's only accessible from localhost.
- **No workspaceOnly**: The agent can write files anywhere locally so it can build real projects in /tmp or user directories.
- **All scripts use `scripts/lib/common.sh`**: Shared library with colors, logging helpers, and project paths. Every script sources it.

## Stack Components

| Component | Port | Purpose |
|-----------|------|---------|
| Ollama | 11434 | Model server |
| claude-code-proxy | 8082 | Anthropic API → OpenAI API translator |
| OpenClaw Gateway | 18789 | Agent manager, dashboard, exec approvals |
| Control Panel | 18790 | Service status, model info, quick actions |

## Common Tasks

- **Change model**: Edit `OLLAMA_MODEL_NAME` in `scripts/lib/common.sh`, update `.proxy/.env`, run `ollama pull <model>`
- **Control panel**: `./dashboard` or `http://localhost:18790`
- **Chat dashboard**: `openclaw dashboard` or `http://localhost:18789`
- **Run tests**: `./test` (or `./test tetris` for one test)
- **Add mesh node**: Add a provider entry to `config/openclaw.json` pointing to the remote Ollama
