# Roadmap: Universal Iteration Engine

*(c) 2026 Matthew Valancy | Valpatel Software*

---

## Philosophy

OpenClaw is open source and had good architectural ideas — session persistence, audit trails, security policies, multi-agent coordination. But it's OpenAI now, so it's dead in the water for us. We don't want that affiliation anywhere in our stack.

We took the best patterns and rebuilt them on Anthropic's Claude Code with fully offline models via Ollama. No cloud APIs. No phone-home. The model runs on your GPU, the agent runs on your CPU, and the iteration engine ties it all together with zero external dependencies.

This roadmap describes two things:
1. **Making the iteration engine universal** — today it only builds HTML5 canvas games. It should build anything.
2. **Building the infrastructure natively** — session persistence, audit logging, security policies, and multi-agent coordination. Ideas borrowed from OpenClaw's architecture, rebuilt from scratch to run offline on Claude Code.

---

## The Problem

Every prompt, health check, and phase selection in `build-project.sh` assumes a web game:

- `prompt_generate()` asks for "HTML5/CSS3/JavaScript", "dark theme", "game logic, rendering, and input"
- `prompt_improve()` suggests "particle effects", "start screen", "high scores", "sound effects via Web Audio API"
- `prompt_features()` suggests "gameplay mechanic, power-up, procedural music"
- `prompt_test()` references "game states", "score", "lives"
- `run_health_check()` opens `index.html` in Playwright, checks canvas pixels, simulates arrow keys
- `run_headless_health_check()` only does syntax checks for non-web projects

If you run `./iterate "Build a REST API for a bookstore"`, it will ask for canvas rendering, dark theme CSS, and arrow key controls. The health check will fail because there's no `index.html`.

---

## Part 1: Universal Project Types

### 1. Project Type Detection

Add `detect_project_type()` that classifies the project automatically from the description and existing files.

| Type | Description | Example |
|------|-------------|---------|
| `web-game` | HTML5 canvas/DOM game | "Build a Tetris game" |
| `web-app` | Web UI (dashboard, form app) | "Build a task manager with a web UI" |
| `api` | REST/GraphQL backend | "Build a REST API for a bookstore" |
| `cli` | Command-line tool | "Build a CLI that converts CSV to JSON" |
| `library` | Reusable module/package | "Build a date formatting library" |
| `self` | Modifying Tritium Coder itself | `./iterate "Improve status.sh" --dir .` |

Detection logic:
1. Parse description for keywords ("API", "REST", "CLI", "game", "dashboard", "library")
2. If `--dir .` or output dir is the project root → `self`
3. If existing files: check extensions, `package.json`, `requirements.txt`, `index.html` presence

Everything else in this roadmap depends on knowing the project type.

### 2. Type-Specific Generate Prompts

The starting point must be correct. Currently `prompt_generate()` tells every project to use "HTML5/CSS3/JavaScript" and "work by opening index.html in a browser."

Each type needs its own generation prompt:
- **web-game**: Keep current prompt (it works)
- **web-app**: HTML/CSS/JS, but focus on layout, forms, data display — not game mechanics
- **api**: Python (Flask/FastAPI) or Node (Express), focus on endpoints, error handling, data validation. No `index.html`. Verify step: `curl http://localhost:PORT/endpoint`
- **cli**: Python or Node, argparse/commander, focus on input parsing, output formatting. Verify step: `./tool --help && echo "test" | ./tool`
- **library**: Module with clean API, docstrings, type hints, example usage
- **self**: Read CLAUDE.md, understand existing architecture, make targeted changes

### 3. Type-Specific Health Checks

The Playwright health check only works for web projects. The fallback only does syntax checks. Each type needs validation that actually proves it works:

| Type | Health Check |
|------|-------------|
| `web-game` / `web-app` | Playwright: load, render, interact, check JS errors (existing) |
| `api` | Start server → `curl` endpoints → check HTTP status codes → verify JSON → kill server |
| `cli` | Run with `--help` (no crash?) → run with sample input (produces output?) → check exit codes |
| `library` | Import test (`python3 -c "import mod"` or `node -e "require('./mod')"`) → run tests if they exist |
| `self` | Run `./test` → `bash -n` on modified scripts |

All types produce the same interface: `HEALTH_STATUS` (PASS/WARN/FAIL), `HEALTH_DETAILS` (specific errors).

### 4. Actionable Error Reporting

Current errors are too vague for the AI to fix. "App FAILED to load" doesn't say WHY.

What we need:
```
FAIL: App loads but crashes immediately
  ERRORS (3):
    1. ReferenceError: gameLoop is not defined (game.js:42)
    2. 404: /js/utils.js (referenced in index.html line 8)
    3. TypeError: Cannot read property 'getContext' of null (render.js:15)
  CATEGORY: Missing files + undefined references
  SUGGESTED FIX: Create js/utils.js or fix the script src path
```

Changes to the Playwright health check:
- Add `page.on("requestfailed")` to capture 404'd resources
- Include full stack traces (first 5 errors), not just counts
- Categorize errors: `reference_error`, `type_error`, `network_error`, `syntax_error`
- Generate a `SUGGESTED FIX` direction so `prompt_fix()` has a starting point

### 5. Type-Aware Phase Prompts

Every `prompt_*` function assumes games. Make them dispatch by project type:

| Function | Current (game-only) | Universal |
|----------|---------------------|-----------|
| `prompt_improve()` | "particle effects, start screen, high scores" | API: "validation, pagination, rate limiting" / CLI: "progress bars, colored output, config files" |
| `prompt_features()` | "gameplay mechanic, power-up" | API: "new endpoint, auth, caching" / CLI: "new subcommand, output formats" |
| `prompt_test()` | "game states, score, lives" via TritiumTest | API: pytest/jest with HTTP calls / CLI: shell-based I/O tests |
| `prompt_runtests()` | "Can user start the game?" | API: "Do endpoints return correct data?" / CLI: "Does --help work?" |
| `prompt_refactor()` | "Separate game logic from rendering" | API: "Separate routes from business logic" / CLI: "Separate parsing from processing" |

### 6. Feedback Loop Closure

The biggest gap: health check finds specific errors, but `prompt_fix()` doesn't always pass them through clearly.

Fix:
1. Pass structured `HEALTH_DETAILS` (from #4) directly into `prompt_fix()`
2. For resource 404s: list exact missing file paths so the AI creates them
3. For reference errors: list exact undefined symbols and which file references them
4. Include the error category and suggested fix direction

This closes the loop: health check → specific error → targeted fix prompt → verify fix.

---

## Part 2: Infrastructure (Borrowed from OpenClaw, Built Natively)

OpenClaw got these right architecturally. We're taking the patterns and building them into Tritium Coder's bash engine — no external framework, no runtime dependencies.

### 7. Session Persistence

OpenClaw persists session state so you can stop and resume. We need the same, built natively.

Session file at `${OUTPUT_DIR}/.tritium-session.json`:
```json
{
  "project_type": "web-game",
  "description": "Build a Tetris game",
  "cycle_count": 7,
  "last_health": "PASS",
  "last_phase": "polish",
  "cycle_history": ["Cycle #1 (generate): Created initial files", "..."],
  "phase_scores": {"fix": 8, "improve": 7},
  "total_elapsed_secs": 3600
}
```

New file `scripts/lib/session.sh`:
- `save_session()` — write state after each cycle
- `load_session()` — restore on `--resume`
- `--resume <name>` — full resume with cycle history, health state, phase scores

### 8. Structured Audit Logging

OpenClaw logs every agent action as structured events. We need the same for debugging and monitoring.

Add `tlog_json()` to `scripts/lib/common.sh`:
- Write JSONL to `logs/tritium-audit.jsonl`
- Each entry: `{"ts":"...","event":"cycle_start","phase":"fix","health":"FAIL","duration_secs":45}`
- Key events: `cycle_start`, `cycle_end`, `health_check`, `agent_call`, `git_checkpoint`, `vision_gate`
- Keep plain-text `tlog()` for humans

### 9. Security Policy Config

OpenClaw has tool-level security policies. We need boundaries documented now and enforced later.

New file `config/security.json`:
```json
{
  "allow": ["read", "write", "bash", "glob", "grep"],
  "deny_commands": ["sudo", "rm -rf /", "curl *.exe"],
  "restrict_paths": {
    "write": ["$OUTPUT_DIR", "/tmp/tritium-*"],
    "read": ["$OUTPUT_DIR", "$PROJECT_DIR", "/tmp"]
  },
  "max_file_size_bytes": 1048576,
  "max_command_timeout_secs": 300
}
```

Claude Code runs with `--dangerously-skip-permissions` today. This config documents intended boundaries. Enforcement comes when Claude Code supports programmatic permission policies, or via a wrapper script. The timeout in `agent_code()` already provides basic runtime limits.

---

## Part 3: Future — Multi-Agent Coordination

This is the most ambitious OpenClaw pattern worth stealing. Multiple AI agents working on different parts of a project simultaneously, coordinated by the iteration engine.

The vision:
- **Architect agent** analyzes the project and breaks work into tasks
- **Coder agents** (multiple) work on separate files/modules in parallel
- **Reviewer agent** validates changes don't conflict and pass health checks
- **The iteration engine** orchestrates all of it — assigns work, resolves conflicts, manages the shared state

This requires the foundation above (universal project types, session persistence, audit logging) to be solid first. One agent doing everything well beats three agents stepping on each other.

---

## Implementation Priority

| Priority | Change | Why |
|----------|--------|-----|
| **P0** | Project type detection (#1) | Everything else depends on this |
| **P0** | Type-specific generate (#2) | Starting point must be correct |
| **P0** | Type-specific health checks (#3) | Feedback loop won't work without this |
| **P1** | Actionable error reporting (#4) | Dramatically improves fix success rate |
| **P1** | Type-aware phase prompts (#5) | Makes improve/features/test useful for non-games |
| **P1** | Feedback loop closure (#6) | Connects health errors to fix prompts |
| **P2** | Session persistence (#7) | Enables resume, saves progress |
| **P2** | Audit logging (#8) | Debugging and monitoring |
| **P3** | Security config (#9) | Documentation now, enforcement later |
| **P3** | Multi-agent (#Part 3) | Requires solid single-agent foundation |

## Files to Modify

| File | Changes |
|------|---------|
| `scripts/build-project.sh` | `detect_project_type()`, refactor all 10 `prompt_*` functions, expand health checks, improve error reporting |
| `scripts/lib/common.sh` | Add `tlog_json()` for structured audit logging |
| `scripts/lib/session.sh` | **New** — session save/load/resume |
| `config/security.json` | **New** — security policy config |

## Verification

Test each project type with a quick run:

```bash
# Web game (existing behavior — regression test)
./iterate "Build a Pong game" --hours 0.15 --no-vision

# API
./iterate "Build a REST API for a todo list with Flask" --hours 0.15 --no-vision

# CLI
./iterate "Build a CLI tool that converts CSV to JSON" --hours 0.15 --no-vision

# Resume
./iterate "Build a calculator app" --hours 0.05 --no-vision
# (kill it)
./iterate --resume calculator-app --hours 0.15 --no-vision

# Self-modification
./iterate "Add colored output to status.sh" --dir . --hours 0.15 --no-vision
```
