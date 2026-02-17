# Tritium Coder — Usage Guide

*How to actually use this system for real coding work.*

*(c) 2026 Matthew Valancy | Valpatel Software*

---

## Quick Reference

```bash
./start.sh          # Start the AI stack (Ollama + proxy + gateway)
./run-claude.sh     # Launch Claude Code with local model (interactive terminal)
./run-openclaw.sh   # Launch OpenClaw agent (interactive terminal)
openclaw dashboard  # Open the web dashboard (chat, config, approvals)
./stop.sh           # Stop everything and free memory
./status.sh         # Check what's running
```

---

## Workflow 1: Claude Code (Recommended)

Claude Code is the primary coding interface. It provides an interactive terminal session where you can ask the model to read, write, and modify code.

### Start a session

```bash
./start.sh           # Start Ollama + proxy (do this once)
./run-claude.sh      # Launch Claude Code
```

### Point it at your project

```bash
./run-claude.sh -p /path/to/your/project
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
./start.sh             # Start Ollama (do this once)
./run-openclaw.sh      # Start gateway + launch agent
```

The script starts the OpenClaw gateway (port 18789) automatically if it isn't running, then drops you into an agent session.

### 2. Give it a job

**Interactive (default):** Just run the script and talk to it:

```bash
./run-openclaw.sh
```

**One-shot:** Pass the task as an argument:

```bash
./run-openclaw.sh "Build a Flask todo app with SQLite. Write it to /tmp/todo-app/app.py and tell me how to run it."
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

The agent runs in **exec allowlist** mode. Pre-approved commands (python3, node, npm, git, ls, cat, mkdir) run automatically. Anything else triggers a prompt.

**Add commands to the allowlist:**

```bash
openclaw approvals allowlist add "pip install"
openclaw approvals allowlist add "pytest"
openclaw approvals allowlist add "docker"
```

**View current allowlist:**

```bash
openclaw approvals allowlist list
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
./run-openclaw.sh "Create a Python Flask todo app in /tmp/my-todo/. Include add, complete, and delete. Use SQLite. Then tell me the exact command to run it."

# Agent works... writes files, reports back with run instructions

# Check the output
ls /tmp/my-todo/
python3 /tmp/my-todo/app.py

# Open browser to http://localhost:5000
```

### Example: Debug an existing project

```bash
./run-openclaw.sh "Read /home/user/project/app.py. It crashes on startup with 'KeyError: db_url'. Find the bug and fix it."
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
| **Shell execution** | `allowlist` | Commands must be explicitly approved. No `apt install`, `pip install`, etc. without your OK. |
| **Filesystem** | `local` | Full local filesystem access. The agent can read/write files anywhere you tell it to. |
| **Browser automation** | `disabled` | No Playwright/Chrome automation. The agent cannot browse the web autonomously. |
| **Web search/fetch** | `enabled` | Can search the web and fetch documentation for research. Read-only. |
| **Elevated permissions** | `disabled` | No sudo, no root. The agent runs with normal user permissions. |
| **Cross-context sends** | `disabled` | Cannot send messages to external services (Telegram, Discord, Slack, etc). |
| **Agent-to-agent** | `disabled` | Cannot spawn or communicate with other agents. |

### Reviewing the config

The security config lives at `config/openclaw.json` and is applied to `~/.openclaw/openclaw.json` during install and when running `./run-openclaw.sh`.

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

To allow specific shell commands without prompting:

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

After `./start.sh`, the model stays in memory. Don't run `./stop.sh` between sessions unless you need the RAM.

### Monitor resource usage

```bash
./status.sh                          # Quick overview
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

## Troubleshooting

### Empty or garbled responses

The model may need more context. Try:
- Adding a system prompt that specifies the task clearly
- Reducing `num_ctx` if memory is tight
- Checking `./status.sh` to verify the model is loaded

### Proxy connection refused

```bash
./status.sh               # Check if proxy is running
./stop.sh && ./start.sh   # Restart everything
```

### Out of memory

```bash
./stop.sh                              # Free model memory
QUANT=UD-TQ1_0 ./install.sh           # Use a smaller quantization
```
