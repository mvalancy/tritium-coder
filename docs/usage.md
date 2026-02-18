# Tritium Coder — Usage Guide

*How to actually use this system for real coding work.*

*(c) 2026 Matthew Valancy | Valpatel Software*

---

## Quick Reference

```bash
./start                   # Start the AI stack (Ollama + proxy + gateway)
./dashboard               # Open control panel (service status, quick actions)
openclaw dashboard        # Open OpenClaw chat dashboard
scripts/run-claude.sh     # Launch Claude Code with local model (interactive terminal)
scripts/run-openclaw.sh   # Launch OpenClaw agent (interactive terminal)
./iterate "description"   # Build any project from a text description
./stop                    # Stop everything and free memory
./status                  # Check what's running
./test                    # Run test suite
```

---

## Control Panel

The control panel is a lightweight web UI for monitoring the stack at a glance.

```bash
./dashboard     # Starts the panel and opens your browser
```

**What it shows:**
- **Services** — live status of Ollama, Proxy, and Gateway (green/red dots)
- **Model** — which model is loaded, size, tool calling support
- **Resources** — estimated memory and GPU usage when model is loaded
- **Quick Actions** — buttons to open chat, send test jobs, view logs, copy terminal commands
- **Activity Log** — timestamped event log, auto-refreshes every 15 seconds

The panel runs on `http://localhost:18790` and polls the services directly from your browser. It's separate from the OpenClaw chat dashboard (port 18789).

**Stop the panel:**
```bash
./stop          # Stops everything including the panel
```

---

## Workflow 1: Claude Code (Recommended)

Claude Code is the primary coding interface. It provides an interactive terminal session where you can ask the model to read, write, and modify code.

### Start a session

```bash
scripts/start.sh           # Start Ollama + proxy (do this once)
scripts/run-claude.sh      # Launch Claude Code
```

### Point it at your project

```bash
scripts/run-claude.sh -p /path/to/your/project
```

Or just `cd` into your project first:

```bash
cd ~/projects/my-app
~/Code/local-agent/run-claude.sh
```

### What you can do

**Write new code:**
```
> Write a REST API in Python using Flask with endpoints for users CRUD
```

**Modify existing code:**
```
> Read app.py and add input validation to the create_user endpoint
```

**Debug:**
```
> I'm getting a KeyError on line 42 of parser.py. Read the file and fix it.
```

**Refactor:**
```
> Refactor the database module to use connection pooling
```

**Explain code:**
```
> Explain what the transform() function in pipeline.py does
```

**Generate tests:**
```
> Write unit tests for the auth module using pytest
```

### Tips for best results

- **Be specific.** "Add error handling to the login function" works better than "improve the code."
- **Reference files by name.** The model can read and edit files in your project directory.
- **Break big tasks into steps.** Ask for one thing at a time for more reliable output.
- **Review before applying.** The model shows you diffs. Review them before accepting.
- **Give context.** Tell the model what framework you're using, what the project does, what conventions to follow.

### Example session: Iterating on a project

```
> Read README.md to understand this project

> Read src/server.js and suggest improvements

> Add rate limiting middleware to the Express server in src/server.js

> Now add a config file for the rate limit settings

> Write tests for the rate limiting middleware using jest
```

---

## Workflow 2: Direct Ollama API

For scripted or batch code generation, you can call the model directly through the Ollama API. This is useful for automation, CI pipelines, or custom tooling.

### Simple code generation

```bash
curl -s http://localhost:11434/api/generate \
  -d '{
    "model": "qwen3-coder-next",
    "prompt": "Write a Python function that validates email addresses using regex. Return only the code.",
    "stream": false
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
```

### Chat-style conversation

```bash
curl -s http://localhost:11434/api/chat \
  -d '{
    "model": "qwen3-coder-next",
    "messages": [
      {"role": "system", "content": "You are a coding assistant. Write clean, production-ready code."},
      {"role": "user", "content": "Write a TypeScript function to debounce API calls with a configurable delay."}
    ],
    "stream": false
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['message']['content'])"
```

### Feed a file for review

```bash
CODE=$(cat src/database.py)
curl -s http://localhost:11434/api/generate \
  -d "{
    \"model\": \"qwen3-coder-next\",
    \"prompt\": \"Review this code for bugs and suggest improvements:\\n\\n${CODE}\",
    \"stream\": false
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
```

### Batch processing with a script

```bash
#!/usr/bin/env bash
# generate-docstrings.sh — Add docstrings to all Python files
for f in src/*.py; do
    echo "Processing $f..."
    CODE=$(cat "$f")
    RESULT=$(curl -s http://localhost:11434/api/generate \
      -d "{
        \"model\": \"qwen3-coder-next\",
        \"prompt\": \"Add Google-style docstrings to all functions in this Python file. Return the complete file with docstrings added:\\n\\n${CODE}\",
        \"stream\": false
      }" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])")
    echo "$RESULT" > "${f}.reviewed"
    echo "  -> ${f}.reviewed"
done
```

---

## Workflow 3: OpenClaw (Autonomous Agent)

OpenClaw runs the model as an autonomous coding agent. You give it a job, it writes code, runs commands, reads/edits files, and reports back. This is the "fire and forget" workflow — give it a task, let it work, review the results.

### 1. Start the stack

```bash
scripts/start.sh             # Start Ollama (do this once)
scripts/run-openclaw.sh      # Start gateway + launch agent
```

The script starts the OpenClaw gateway (port 18789) automatically if it isn't running, then drops you into an agent session.

### 2. Give it a job

**Interactive (default):** Just run the script and talk to it:

```bash
scripts/run-openclaw.sh
```

**One-shot:** Pass the task as an argument:

```bash
scripts/run-openclaw.sh "Build a Flask todo app with SQLite. Write it to /tmp/todo-app/app.py and tell me how to run it."
```

**Headless (background):** Run a job and capture JSON output:

```bash
openclaw agent \
  --session-id "my-job" \
  --message "Write a REST API for a bookstore in /tmp/bookstore/" \
  --thinking medium --json --timeout 600
```

### 3. Monitor progress

**Tail the gateway log live:**

```bash
openclaw logs --follow
```

Or read the log file directly:

```bash
tail -f ~/Code/local-agent/logs/openclaw-gateway.log
```

**Check gateway health:**

```bash
openclaw health
```

### 4. Manage sessions

**List all sessions:**

```bash
openclaw sessions
```

**Resume a previous session** (continue where you left off):

```bash
openclaw agent --session-id "my-job" --message "Now add unit tests"
```

Sessions persist across restarts. You can pick up any previous conversation.

### 5. Approve commands

The agent runs in **full exec** mode — it can run any shell command without approval prompts. This lets it install dependencies, run tests, and build projects autonomously.

**Safety limits still apply:** no sudo, no elevated permissions, no browser automation. The agent runs as your normal user.

To switch to a more restrictive allowlist mode, edit `config/openclaw.json`:

```json
"exec": { "security": "allowlist", "safeBins": ["python3", "node", "git", "ls", "cat", "mkdir"] }
```

### 6. Review the output

The agent writes files directly to wherever you told it. Check the results:

```bash
ls /tmp/todo-app/
python3 /tmp/todo-app/app.py
```

### Example: Build and test a web app

```bash
# Give the job
scripts/run-openclaw.sh "Create a Python Flask todo app in /tmp/my-todo/. Include add, complete, and delete. Use SQLite. Then tell me the exact command to run it."

# Agent works... writes files, reports back with run instructions

# Check the output
ls /tmp/my-todo/
python3 /tmp/my-todo/app.py

# Open browser to http://localhost:5000
```

### Example: Debug an existing project

```bash
scripts/run-openclaw.sh "Read /home/user/project/app.py. It crashes on startup with 'KeyError: db_url'. Find the bug and fix it."
```

### Example: Scheduled tasks (cron)

```bash
openclaw cron add --schedule "0 */6 * * *" \
  --message "Run the test suite at /home/user/project/ and report failures"
```

---

## Workflow 4: Proxy Chain (Advanced)

The proxy translates Anthropic's Messages API into OpenAI format. Any tool that speaks Anthropic API can use your local model.

### Direct API call through the proxy

```bash
curl -s http://localhost:8082/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: local-qwen3-coder-next" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 4096,
    "messages": [
      {"role": "user", "content": "Write a Dockerfile for a Node.js Express app with multi-stage build"}
    ]
  }' | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['content'][0]['text'])"
```

The proxy maps all model names to your local model. Any Anthropic API client will work.

### Use with other Anthropic-compatible tools

Set these environment variables in any tool that uses the Anthropic API:

```bash
export ANTHROPIC_BASE_URL="http://localhost:8082"
export ANTHROPIC_API_KEY="local-qwen3-coder-next"
```

---

## Security Model

Tritium Coder is configured for **local coding work only**. The OpenClaw config enforces these boundaries:

| Control | Setting | What It Means |
|---------|---------|---------------|
| **Gateway binding** | `loopback` | Localhost only by default. Add Tailscale Serve for HTTPS remote access on your private Tailnet. Token auth required. |
| **Shell execution** | `full` | Agent can run any command. No sudo or elevated permissions. |
| **Filesystem** | `local` | Full local filesystem access. The agent can read/write files anywhere you tell it to. |
| **Browser automation** | `disabled` | No Playwright/Chrome automation. The agent cannot browse the web autonomously. |
| **Web search/fetch** | `enabled` | Can search the web and fetch documentation for research. Read-only. |
| **Elevated permissions** | `disabled` | No sudo, no root. The agent runs with normal user permissions. |
| **Cross-context sends** | `disabled` | Cannot send messages to external services (Telegram, Discord, Slack, etc). |
| **Agent-to-agent** | `disabled` | Cannot spawn or communicate with other agents. |

### Reviewing the config

The security config lives at `config/openclaw.json` and is applied to `~/.openclaw/openclaw.json` during install and when running `scripts/run-openclaw.sh`.

To audit your current setup:

```bash
openclaw security audit
openclaw security audit --deep    # includes live gateway checks
```

### Customizing security

Edit `config/openclaw.json` to adjust. For example, to completely disable web access:

```json
"web": {
  "search": { "enabled": false },
  "fetch": { "enabled": false }
}
```

To restrict which commands the agent can run (default is `full`):

```json
"exec": {
  "security": "allowlist",
  "safeBins": ["python3", "node", "git", "ls", "cat"]
}
```

---

## Performance Tips

### First response is slow

The model needs a few seconds to produce the first token. This is normal for large models. Subsequent tokens stream faster (Qwen3-Coder-Next is an 80B MoE model with only 3B active parameters per token, so inference is efficient).

### Keep the model loaded

After `scripts/start.sh`, the model stays in memory. Don't run `scripts/stop.sh` between sessions unless you need the RAM.

### Monitor resource usage

```bash
scripts/status.sh                          # Quick overview
watch -n 2 nvidia-smi                # GPU utilization
watch -n 2 free -h                   # Memory usage
```

---

## Common Patterns

### Code review workflow

1. Start Claude Code in your project directory
2. Ask it to read the files you want reviewed
3. Ask for specific feedback: security, performance, style, bugs
4. Apply suggestions selectively

### New feature workflow

1. Describe the feature and its requirements
2. Ask the model to design the approach first (don't jump to code)
3. Generate code file by file
4. Ask for tests
5. Review and iterate

### Debugging workflow

1. Share the error message or stack trace
2. Point the model at the relevant source files
3. Ask it to identify the root cause
4. Ask for a fix, review the diff

### Documentation workflow

1. Point the model at your codebase
2. Ask it to generate README sections, API docs, or inline comments
3. Use the direct API (Workflow 2) for batch doc generation across many files

---

## Workflow 5: Perpetual Iteration Engine (Build System)

The build system is an autonomous loop that generates any project from a text description, then iteratively improves it. The vision: **perpetual motion** — AI builds, automated tests validate from a user's perspective, failures drive the next iteration, and the system self-improves.

### Build a single project

```bash
./iterate "Build a Tetris game with HTML5 canvas" --hours 4
./iterate "Create a REST API for a bookstore" --hours 2 --no-vision
./iterate "Refactor the tritium-coder test suite" --dir . --hours 1
```

Options:
- `--hours <n>` — time budget (default: 4)
- `--name <name>` — project name (default: derived from description)
- `--dir <path>` — output directory (default: `examples/<name>`)
- `--no-vision` — skip vision model reviews
- `--vision-model <m>` — vision model (default: `qwen3-vl:32b`)

### Build all example projects

```bash
scripts/create-examples.sh        # 4 hours per project (default)
scripts/create-examples.sh 2      # 2 hours per project
```

Edit `scripts/create-examples.sh` to add your own project descriptions.

### The iteration cycle

Each cycle:

1. **Health check** — Playwright loads the app in a headless browser. Does it load? Render visible content? Respond to input? Survive 10 seconds? Any JS console errors?
2. **Phase selection** — Based on health (PASS/WARN/FAIL), file sizes, and maturity tier (early/mid/late):
   - App broken → **fix** (focused on the specific failure: blank screen, crash, dead controls)
   - App has warnings → **fix**
   - Files too large (>1500 lines) → **refactor** (split into modules)
   - App works, early maturity → **improve** or **features** (one thing at a time, done well)
   - App works, mid maturity → **polish**, **test**, **runtests**
   - App works, late maturity → **consolidate** (remove dead code), **docs**
3. **Code pass** — One focused prompt to the AI agent (ask for 1 thing, do it well)
4. **Git checkpoint** — Auto-commit after constructive phases
5. **Vision gate** — After polish/runtests, screenshots at 5 resolutions reviewed by vision model

### Philosophy: zero-trust validation

The system never trusts that code works because the AI said so.

- **Health checks** verify from a real user's perspective: load the app, interact with it, check for crashes
- **Prompts** emphasize user experience: "would a real person have a good experience?" not "does the code look correct?"
- **Tests** are written as category nets catching classes of bugs (rendering failures, state corruption, dead input) — not individual bug checks
- **Vision gate** reviews multi-resolution screenshots with a brutal QA lens

### Output structure

Each project built by the system maintains:

```
examples/tetris/
  index.html           # The app
  *.js, *.css           # Source files
  test.html             # Test suite (uses lib/test-harness.js)
  README.md             # Auto-generated with features and screenshots
  screenshots/          # Captured at desktop, tablet, mobile, ultrawide
  docs/                 # Architecture notes
```

### Shared test harness

All generated projects use `lib/test-harness.js` — a lightweight browser test framework:

```html
<script src="../../lib/test-harness.js"></script>
<script>
  const t = new TritiumTest('My Game');
  t.test('app initializes', () => { t.assertNoThrow(() => initGame()); });
  t.test('visible content renders', () => { t.assertExists('canvas'); });
  t.test('score is valid', () => { t.assertType(game.score, 'number'); });
  t.run();
</script>
```

### Monitoring a running build

```bash
tail -f logs/iterate-tetris.log     # Watch iteration progress
./status                            # Check if services are running
```

The log shows every cycle: phase selected, health status, maturity tier, response length, git checkpoints, vision gate results.

---

## Troubleshooting

### Empty or garbled responses

The model may need more context. Try:
- Adding a system prompt that specifies the task clearly
- Reducing `num_ctx` if memory is tight
- Checking `scripts/status.sh` to verify the model is loaded

### Proxy connection refused

```bash
scripts/status.sh               # Check if proxy is running
scripts/stop.sh && scripts/start.sh   # Restart everything
```

### Out of memory

```bash
scripts/stop.sh                              # Free model memory
QUANT=UD-TQ1_0 ./install.sh           # Use a smaller quantization
```
