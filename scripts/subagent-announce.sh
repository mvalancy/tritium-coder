#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Sub-Agent Announce Flow
# =============================================================================
# Purpose: Process sub-agent completion and announce results to parent
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/session-key.sh"
source "$SCRIPT_DIR/lib/session.sh"

REGISTRY_FILE="${PROJECT_DIR}/.tritium-subagents/runs.json"

# =============================================================================
#  Announce Flow
# =============================================================================

announce_subagent_result() {
    local run_id="$1"
    local child_session_key="$2"
    local result_file="${3:-}"

    # Check if registry exists
    if [ ! -f "$REGISTRY_FILE" ]; then
        log_warn "Announce: Registry not found, cannot announce"
        return 1
    fi

    # Read run record
    local record
    record=$(python3 -c "
import json
with open('$REGISTRY_FILE', 'r') as f:
    d = json.load(f)
if '$run_id' in d.get('runs', {}):
    r = d['runs']['$run_id']
    print(f\"requester={r.get('requesterSessionKey')}\")
    print(f\"task={r.get('task')}\")
    print(f\"label={r.get('label')}\")
    print(f\"model={r.get('model')}\")
    print(f\"cleanup={r.get('cleanup', 'keep')}\")
" 2>/dev/null || echo "")

    if [ -z "$record" ]; then
        log_warn "Announce: Run ID not found in registry: $run_id"
        return 1
    fi

    # Parse record
    local requester task label model cleanup
    requester=$(echo "$record" | grep "^requester=" | cut -d= -f2-)
    task=$(echo "$record" | grep "^task=" | cut -d= -f2-)
    label=$(echo "$record" | grep "^label=" | cut -d= -f2-)
    model=$(echo "$record" | grep "^model=" | cut -d= -f2-)
    cleanup=$(echo "$record" | grep "^cleanup=" | cut -d= -f2-)

    # Get result from child output
    local result_text=""
    if [ -n "$result_file" ] && [ -f "$result_file" ]; then
        result_text=$(cat "$result_file")
    elif [ -f "${PROJECT_DIR}/.tritium-subagents/outputs/agent.log" ]; then
        result_text=$(tail -100 "${PROJECT_DIR}/.tritium-subagents/outputs/agent.log")
    fi

    # Calculate completion time
    local start_time end_time elapsed
    start_time=$(python3 -c "
import json
with open('$REGISTRY_FILE', 'r') as f:
    d = json.load(f)
print(d.get('runs', {}).get('$run_id', {}).get('startedAt', 0)
" 2>/dev/null || echo "0")

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    # Determine status
    local status="completed successfully"
    if [ ! -f "$result_file" ]; then
        status="completed (no result file)"
    fi

    # Build announcement
    local task_display="${label:-$task}"
    local parent_depth
    parent_depth=$(get_subagent_depth "$requester")
    local is_subagent_parent=false
    [ "$parent_depth" -gt 0 ] && is_subagent_parent=true

    local announcement
    announcement=$(cat << EOF
[Sub-Agent Announce]
Session: $child_session_key
Task: "$task_display"
Status: $status
Duration: ${elapsed}s

RESULTS:
$result_text

---
Run ID: $run_id
Model: $model
EOF
)

    # Send to parent
    log_to "ANNOUNCE: Sending to parent $requester"

    if [ "$is_subagent_parent" = true ]; then
        # Sub-agent parent receives as system message
        echo "$announcement" >> "${PROJECT_DIR}/.tritium-subagents/incoming/$(generate_uuid).msg"
        log_to "ANNOUNCE: Queued for sub-agent parent"
    else
        # Main session parent receives directly
        local announce_file="${PROJECT_DIR}/.tritium-announcements/$(generate_uuid).txt"
        echo "$announcement" > "$announce_file"
        log_to "ANNOUNCE: Written to $announce_file"
    fi

    # Update registry
    python3 << PYTHON_EOF
import json
with open("$REGISTRY_FILE", "r") as f:
    registry = json.load(f)
if "$run_id" in registry.get("runs", {}):
    registry["runs"]["$run_id"]["endedAt"] = $end_time
    registry["runs"]["$run_id"]["status"] = "$status"
    registry["runs"]["$run_id"]["completedAt"] = $end_time
with open("$REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)
PYTHON_EOF

    # Cleanup if requested
    if [ "$cleanup" = "delete" ]; then
        log_to "ANNOUNCE: Cleanup requested, removing output"
        rm -rf "${PROJECT_DIR}/.tritium-subagents/outputs/$run_id" 2>/dev/null || true
    fi

    return 0
}

# =============================================================================
#  Process Pending Announcements
# =============================================================================

process_pending_announcements() {
    local incoming_dir="${PROJECT_DIR}/.tritium-subagents/incoming"
    local announcements_dir="${PROJECT_DIR}/.tritium-announcements"

    mkdir -p "$incoming_dir" "$announcements_dir"

    # Process any queued announcements
    for msg_file in "$incoming_dir"/*.msg; do
        [ -f "$msg_file" ] || continue
        log_to "ANNOUNCE: Processing queued message: $msg_file"
        cat "$msg_file"
        rm "$msg_file"
    done

    # List pending announcements
    for announce_file in "$announcements_dir"/*.txt; do
        [ -f "$announce_file" ] || continue
        log_to "ANNOUNCE: Available: $announce_file"
    done
}

# =============================================================================
#  Get Sub-Agent Status
# =============================================================================

list_subagent_runs() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        echo "No sub-agent runs found"
        return
    fi

    python3 << PYTHON_EOF
import json
import time
with open('$REGISTRY_FILE', 'r') as f:
    registry = json.load(f)

print("SUB-AGENT RUNS:")
print("-" * 60)
for run_id, run in registry.get("runs", {}).items():
    status = run.get("status", "running")
    started = run.get("startedAt", 0)
    ended = run.get("endedAt", 0)
    task = run.get("task", "")[:40]
    elapsed = ended - started if ended and started else int(time.time()) - started
    print(f"  {run_id}: {status} ({elapsed}s)")
    print(f"    Task: {task}")
    print(f"    Child: {run.get('childSessionKey', '')}")
    print(f"    Parent: {run.get('requesterSessionKey', '')}")
    print()
PYTHON_EOF
}

# =============================================================================
#  Kill Sub-Agent Run
# =============================================================================

kill_subagent_run() {
    local run_id="$1"

    if [ -z "$run_id" ]; then
        echo "Usage: $0 kill <run_id>"
        list_subagent_runs
        exit 1
    fi

    python3 << PYTHON_EOF
import json
with open('$REGISTRY_FILE', 'r') as f:
    registry = json.load(f)
if "$run_id" in registry.get("runs", {}):
    registry["runs"]["$run_id"]["status"] = "killed"
    registry["runs"]["$run_id"]["endedAt"] = $end_time
    registry["runs"]["$run_id"].pop("expectsCompletionMessage", None)
    with open('$REGISTRY_FILE', "w") as f:
        json.dump(registry, f, indent=2)
    print(f"Killed: $run_id")
else:
    print(f"Not found: $run_id")
PYTHON_EOF
}

# =============================================================================
#  Main CLI
# =============================================================================

case "${1:-announce}" in
    announce)
        announce_subagent_result "$2" "$3" "$4"
        ;;
    list)
        list_subagent_runs
        ;;
    kill)
        kill_subagent_run "$2"
        ;;
    status)
        list_subagent_runs
        ;;
    process)
        process_pending_announcements
        ;;
    *)
        echo "Usage: $0 {announce|list|kill|status|process}"
        exit 1
        ;;
esac
