# Tritium Coder — Project Context

A fully offline AI coding stack. Ollama runs the model on your GPU, Claude Code is the coding agent, Playwright validates the output. No cloud APIs, no external dependencies at runtime.

## Repository Structure

```
tritium-coder/
  install.sh              # One-click installer (downloads model, sets up proxy)
  start, stop, status     # Stack management (thin wrappers)
  test                    # Run test suite
  iterate                 # Build/iterate on any project (wraps build-project.sh)
  dashboard               # Open control panel (localhost:18790)
  CLAUDE.md               # This file
  README.md               # Project overview
  LICENSE                 # MIT
  scripts/
    start.sh              # Start the stack (Ollama + proxy)
    stop.sh               # Stop everything and free memory
    status.sh             # Check what's running
    run-claude.sh         # Launch Claude Code with local model
    build-project.sh      # Core iteration engine (health checks, dynamic phases, vision gate)
    create-examples.sh    # Batch builder for example projects
    lib/
      common.sh           # Shared bash library (colors, logging, paths)
  lib/
    test-harness.js       # Shared browser test framework (TritiumTest class)
  config/                 # Future: native session management, security policies
  web/
    index.html            # Control panel UI (service status, model info, quick actions)
  examples/               # Generated projects (gitignored — built by build-project.sh)
  tests/
    run-all.sh            # Test suite — sends real coding jobs to Claude Code
  docs/
    usage.md              # Detailed usage workflows and examples
    architecture.md       # System architecture with diagrams
    security.md           # Security model and hardening
    mesh.md               # Multi-node setup (experimental)
  .proxy/                 # Claude Code proxy (auto-cloned, gitignored)
  logs/                   # Runtime logs (gitignored)
```

## Key Design Decisions

- **Single model variable**: `OLLAMA_MODEL_NAME` in `scripts/lib/common.sh` controls which model the entire stack uses. Change it there + `.proxy/.env` to swap models.
- **Claude Code as coding agent**: `claude -p` with `--dangerously-skip-permissions` talks to Ollama through the proxy. The agent can write files anywhere so it can build real projects.
- **No external agent frameworks**: Session management, security policies, and orchestration are handled natively by build-project.sh and the bash library. No OpenAI-affiliated dependencies.
- **All scripts use `scripts/lib/common.sh`**: Shared library with colors, logging helpers, and project paths. Every script sources it.

## Stack Components

| Component | Port | Purpose |
|-----------|------|---------|
| Ollama | 11434 | Model server |
| claude-code-proxy | 8082 | Anthropic API → OpenAI API translator |
| Control Panel | 18790 | Service status, model info, quick actions |

## Build System (Perpetual Iteration Engine)

The build system (`scripts/build-project.sh`, invoked via `./iterate`) takes a text description and autonomously builds, tests, and improves a project in a loop.

- **Health checks** every cycle: Playwright loads the app, checks for crashes, blank screens, JS errors, dead controls
- **Dynamic phase selection**: picks fix/improve/features/refactor/consolidate/docs based on health status and maturity
- **Zero-trust**: never trusts AI output — validates from user's perspective, not code review
- **Vision gate**: multi-resolution screenshots reviewed by vision model after polish/test phases
- **Test harness**: `lib/test-harness.js` — shared TritiumTest class for browser-based tests
- **Per-project output**: each project gets its own README.md, screenshots/, docs/, test.html
- **Batch mode**: `scripts/create-examples.sh` feeds multiple project descriptions to build-project.sh

## Common Tasks

- **Change model**: Edit `OLLAMA_MODEL_NAME` in `scripts/lib/common.sh`, update `.proxy/.env`, run `ollama pull <model>`
- **Control panel**: `./dashboard` or `http://localhost:18790`
- **Build a project**: `./iterate "Build a Tetris game" --hours 4`
- **Build all examples**: `scripts/create-examples.sh`
- **Run tests**: `./test` (or `./test tetris` for one test)
