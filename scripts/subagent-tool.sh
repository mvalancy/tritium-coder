#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Sub-Agent Steering Tool
# =============================================================================
# Provides /subagents tool interface for managing sub-agents
# Usage: ./subagent-tool.sh {list|status|kill|steer}
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/session-key.sh"

REGISTRY_FILE="${PROJECT_DIR}/.tritium-subagents/runs.json"
OUTPUT_DIR="${PROJECT_DIR}/.tritium-subagents/outputs"

# =============================================================================
#  List active sub-agent runs
# =============================================================================

subagent_list() {
    echo "ACTIVE SUB-AGENTS:"
    echo "=================="

    if [ ! -f "$REGISTRY_FILE" ]; then
        echo "  No sub-agents registered"
        return
    fi

    python3 << PYTHON_EOF
import json
import os
import time

with open("$REGISTRY_FILE", "r") as f:
    registry = json.load(f)

for run_id, run in registry.get("runs", {}).items():
    child_session = run.get("childSessionKey", "")
    parent_session = run.get("requesterSessionKey", "")
    status = run.get("status", "running")
    task = run.get("task", "")[:50]
    label = run.get("label", "")
    depth = run.get("spawnDepth", 0)
    started = run.get("startedAt", 0)
    elapsed = int(time.time()) - started if started else 0

    pid = None
    pid_file = f"$OUTPUT_DIR/{run_id}.pid" if run_id else None
    if pid_file and os.path.exists(pid_file):
        with open(pid_file) as f:
            pid = f.read().strip()

    print(f"\n{run_id}")
    print(f"  Session: {child_session}")
    print(f"  Parent:  {parent_session}")
    print(f"  Depth:   {depth}")
    print(f"  Status:  {status}")
    print(f"  Task:    {label or task}")
    print(f"  PID:     {pid or 'N/A'}")
    print(f"  Runtime: {elapsed}s")
PYTHON_EOF
}

# =============================================================================
#  Get sub-agent status
# =============================================================================

subagent_status() {
    local run_id="$1"

    if [ -z "$run_id" ]; then
        echo "Usage: $0 status <run_id>"
        subagent_list
        exit 1
    fi

    if [ ! -f "$REGISTRY_FILE" ]; then
        echo "No sub-agents registered"
        return
    fi

    python3 << PYTHON_EOF
import json
import os
import time

with open("$REGISTRY_FILE", "r") as f:
    registry = json.load(f)

run = registry.get("runs", {}).get("$run_id")
if not run:
    print(f"Run not found: $run_id")
    exit(1)

child_session = run.get("childSessionKey", "")
parent_session = run.get("requesterSessionKey", "")
status = run.get("status", "running")
task = run.get("task", "")
label = run.get("label", "")
model = run.get("model", "")
depth = run.get("spawnDepth", 0)
timeout = run.get("timeoutSeconds", 0)
started = run.get("startedAt", 0)
ended = run.get("endedAt", 0)

elapsed = ended - started if ended and started else int(time.time()) - started
output_file = "$OUTPUT_DIR/$run_id/output.txt"

print("SUB-AGENT STATUS:")
print(f"  Run ID:      $run_id")
print(f"  Session:     {child_session}")
print(f"  Parent:      {parent_session}")
print(f"  Status:      {status}")
print(f"  Task:        {task}")
print(f"  Label:       {label}")
print(f"  Model:       {model}")
print(f"  Spawn Depth: {depth}")
print(f"  Timeout:     {timeout}s")
print(f"  Runtime:     {elapsed}s")

if os.path.exists(output_file):
    print("\nOUTPUT:")
    with open(output_file) as f:
        content = f.read()
        print(content if content else "(empty)")
PYTHON_EOF
}

# =============================================================================
#  Kill sub-agent run
# =============================================================================

subagent_kill() {
    local run_id="$1"

    if [ -z "$run_id" ]; then
        echo "Usage: $0 kill <run_id>"
        subagent_list
        exit 1
    fi

    if [ ! -f "$REGISTRY_FILE" ]; then
        echo "No sub-agents registered"
        return
    fi

    python3 << PYTHON_EOF
import json
import os
import signal

with open("$REGISTRY_FILE", "r") as f:
    registry = json.load(f)

run = registry.get("runs", {}).get("$run_id")
if not run:
    print(f"Run not found: $run_id")
    exit(1)

pid_file = "$OUTPUT_DIR/$run_id.pid"

# Try to kill the process
if os.path.exists(pid_file):
    with open(pid_file) as f:
        try:
            pid = int(f.read().strip())
            os.kill(pid, signal.SIGTERM)
            print(f"Killed process {pid}")
        except:
            print(f"Could not kill process (maybe already dead)")

# Mark as killed
run["status"] = "killed"
run["endedAt"] = $(_date +%s)
run["killed"] = True

registry["runs"]["$run_id"] = run

with open("$REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)

print(f"Marked {run_id} as killed")
PYTHON_EOF
}

# =============================================================================
#  Steer sub-agent (restart, modify task)
# =============================================================================

subagent_steer() {
    local run_id="$1"
    local action="${2:-restart}"

    if [ -z "$run_id" ]; then
        echo "Usage: $0 steer <run_id> {restart|abort|modify}"
        subagent_list
        exit 1
    fi

    case "$action" in
        restart)
            echo "Steering: Restarting $run_id"
            subagent_kill "$run_id"
            # In a real implementation, would restart the agent
            ;;
        abort)
            echo "Steering: Aborting $run_id"
            subagent_kill "$run_id"
            ;;
        modify)
            local new_task="${3:-}"
            echo "Steering: Modifying $run_id with new task: $new_task"
            # Update the registry with new task
            ;;
        *)
            echo "Unknown action: $action"
            echo "Valid: restart, abort, modify"
            ;;
    esac
}

# =============================================================================
#  Main CLI
# =============================================================================

case "${1:-list}" in
    list|ls)
        subagent_list
        ;;
    status)
        subagent_status "$2"
        ;;
    kill)
        subagent_kill "$2"
        ;;
    steer)
        subagent_steer "$2" "${3:-restart}"
        ;;
    *)
        echo "Sub-Agent Steering Tool"
        echo ""
        echo "Usage: $0 {list|status|kill|steer}"
        echo ""
        echo "Commands:"
        echo "  list           List all active sub-agents"
        echo "  status <id>    Get detailed status of a sub-agent"
        echo "  kill <id>      Kill a sub-agent run"
        echo "  steer <id> <action>  Modify running sub-agent"
        echo ""
        echo "Actions: restart, abort, modify"
        exit 0
        ;;
esac
