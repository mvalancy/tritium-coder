# Tritium Coder — Project Context

This is a local AI coding stack that runs on NVIDIA hardware (GB10, Jetson, RTX workstations). It wires together Ollama, OpenClaw, and Claude Code into a single install.

## Repository Structure

```
tritium-coder/
  install.sh              # Top-level installer (run once)
  start, stop, status     # Top-level commands (thin wrappers)
  test                    # Run test suite
  iterate                 # Build/iterate on any project (wraps build-project.sh)
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
    build-project.sh      # Core iteration engine (health checks, dynamic phases, vision gate)
    create-examples.sh    # Batch builder for example projects
    lib/
      common.sh           # Shared bash library (colors, logging, paths)
  lib/
    test-harness.js       # Shared browser test framework (TritiumTest class)
  config/
    openclaw.json         # Hardened OpenClaw config template
  web/
    index.html            # Control panel UI (service status, model info, quick actions)
  examples/               # Generated projects (gitignored — built by build-project.sh)
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

## Build System (Perpetual Iteration Engine)

The build system (`scripts/build-project.sh`, invoked via `./iterate`) takes a text description and autonomously builds, tests, and improves a project in a loop.

- **Health checks** every cycle: playwright loads the app, checks for crashes, blank screens, JS errors, dead controls
- **Dynamic phase selection**: picks fix/improve/features/refactor/consolidate/docs based on health status and maturity
- **Zero-trust**: never trusts AI output — validates from user's perspective, not code review
- **Vision gate**: multi-resolution screenshots reviewed by vision model after polish/test phases
- **Test harness**: `lib/test-harness.js` — shared TritiumTest class for browser-based tests
- **Per-project output**: each project gets its own README.md, screenshots/, docs/, test.html
- **Batch mode**: `scripts/create-examples.sh` feeds multiple project descriptions to build-project.sh

## Common Tasks

- **Change model**: Edit `OLLAMA_MODEL_NAME` in `scripts/lib/common.sh`, update `.proxy/.env`, run `ollama pull <model>`
- **Control panel**: `./dashboard` or `http://localhost:18790`
- **Chat dashboard**: `openclaw dashboard` or `http://localhost:18789`
- **Build a project**: `./iterate "Build a Tetris game" --hours 4`
- **Build all examples**: `scripts/create-examples.sh`
- **Run tests**: `./test` (or `./test tetris` for one test)
- **Add mesh node**: Add a provider entry to `config/openclaw.json` pointing to the remote Ollama
