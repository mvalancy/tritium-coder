#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Sub-Agent Spawning Tool
# =============================================================================
# Usage: ./subagent-spawn.sh --task "description" --label "name" --depth 1
# =============================================================================
# This tool spawns a sub-agent with depth constraints and tracks the run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/session-key.sh"
source "$SCRIPT_DIR/lib/project-type.sh"
source "$SCRIPT_DIR/lib/session.sh"

# =============================================================================
#  Configuration
# =============================================================================

# Maximum spawn depth (0 = no sub-agents, 1 = one level, 2 = nested)
MAX_SPAWN_DEPTH="${MAX_SPAWN_DEPTH:-1}"

# Per-agent max children limit
MAX_CHILDREN_PER_AGENT="${MAX_CHILDREN_PER_AGENT:-5}"

# Sub-agent registry file (persisted across runs)
REGISTRY_FILE="${PROJECT_DIR}/.tritium-subagents/runs.json"

# =============================================================================
#  Command Line Parsing
# =============================================================================

TASK=""
LABEL=""
MODEL="${OLLAMA_MODEL_NAME:-claude-sonnet-4-6}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
DEPTH="${MAX_SPAWN_DEPTH}"
TIMEOUT=600
CLEANUP="keep"
DELIVER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            TASK="$2"
            shift 2
            ;;
        --label)
            LABEL="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --ollama-host)
            OLLAMA_HOST="$2"
            shift 2
            ;;
        --depth)
            DEPTH="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --cleanup)
            CLEANUP="$2"
            shift 2
            ;;
        --deliver)
            DELIVER=true
            shift
            ;;
        --help)
            echo "Usage: $0 --task DESCRIPTION --label NAME [options]"
            echo ""
            echo "Options:"
            echo "  --task       Task description (required)"
            echo "  --label      Human-readable label for the task"
            echo "  --model      Model to use (default: OLLAMA_MODEL_NAME)"
            echo "  --ollama-host Ollama host URL (default: http://localhost:11434)"
            echo "  --depth      Spawn depth limit (default: MAX_SPAWN_DEPTH)"
            echo "  --timeout    Timeout in seconds (default: 600)"
            echo "  --cleanup    Delete after completion: delete|keep (default: keep)"
            echo "  --deliver    Send results to parent (default: false)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
#  Validation
# =============================================================================

# Parse current session to get spawn depth
CURRENT_SESSION_KEY="agent:${TRITIUM_AGENT_ID:-tritium}:main"
CURRENT_DEPTH=$(get_subagent_depth "$CURRENT_SESSION_KEY")

if [ "$CURRENT_DEPTH" -ge "$MAX_SPAWN_DEPTH" ]; then
    echo "ERROR: Max spawn depth ($MAX_SPAWN_DEPTH) reached at depth $CURRENT_DEPTH"
    exit 1
fi

# Check child limit
CURRENT_CHILDREN=0
[ -f "$REGISTRY_FILE" ] && CURRENT_CHILDREN=$(python3 -c "import json; d=json.load(open('$REGISTRY_FILE')); print(len([r for r in d.get('runs', {}).values() if r.get('spawnedBy') == '$CURRENT_SESSION_KEY']))" 2>/dev/null || echo "0")

if [ "$CURRENT_CHILDREN" -ge "$MAX_CHILDREN_PER_AGENT" ]; then
    echo "ERROR: Max children ($MAX_CHILDREN_PER_AGENT) reached"
    exit 1
fi

# =============================================================================
#  Spawning Logic
# =============================================================================

mkdir -p "$(dirname "$REGISTRY_FILE")"

GEN_UUID=$(generate_uuid)
CHILD_SESSION_KEY="${CURRENT_SESSION_KEY}:subagent:${GEN_UUID}"
CHILD_DEPTH=$((CURRENT_DEPTH + 1))
RUN_ID=$(generate_run_id)
START_TIME=$(date +%s)

log_to "SPAWN: Creating sub-agent session $CHILD_SESSION_KEY"
log_to "SPAWN: Task='$LABEL' at depth $CHILD_DEPTH"

# Create child registry entry
if [ ! -f "$REGISTRY_FILE" ]; then
    cat > "$REGISTRY_FILE" << EOF
{
  "version": 2,
  "runs": {}
}
EOF
fi

# Add run to registry
python3 << PYTHON_EOF
import json

registry = {"version": 2, "runs": {}}
try:
    with open("$REGISTRY_FILE", "r") as f:
        registry = json.load(f)
except: pass

registry["runs"]["$RUN_ID"] = {
    "runId": "$RUN_ID",
    "childSessionKey": "$CHILD_SESSION_KEY",
    "requesterSessionKey": "$CURRENT_SESSION_KEY",
    "spawnedBy": "$CURRENT_SESSION_KEY",
    "task": "$TASK",
    "label": "$LABEL",
    "model": "$MODEL",
    "spawnDepth": $CHILD_DEPTH,
    "timeoutSeconds": $TIMEOUT,
    "cleanup": "$CLEANUP",
    "createdAt": $START_TIME,
    "startedAt": $START_TIME,
    "expectsCompletionMessage": $DELIVER
}

with open("$REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)
PYTHON_EOF

# Create output directory for child
OUTPUT_DIR="${PROJECT_DIR}/.tritium-subagents/outputs/$GEN_UUID"
mkdir -p "$OUTPUT_DIR"

# Write task file
cat > "${OUTPUT_DIR}/.tritium-task.txt" << EOF
Task: $LABEL
Description: $TASK
Parent Session: $CURRENT_SESSION_KEY
Child Session: $CHILD_SESSION_KEY
Spawned By Sub-Agent
EOF

# Build system prompt for child
SYS_PROMPT=$(cat << 'EOF'
# You are a Sub-Agent

You were spawned to complete a specific task. Your entire purpose is to finish this task.

## Your Task
EOF
)
echo "$SYS_PROMPT" > "${OUTPUT_DIR}/.tritium-system.txt"
echo "Task: $LABEL" >> "${OUTPUT_DIR}/.tritium-system.txt"
echo "Description: $TASK" >> "${OUTPUT_DIR}/.tritium-system.txt"
echo "" >> "${OUTPUT_DIR}/.tritium-system.txt"
cat << 'EOF' >> "${OUTPUT_DIR}/.tritium-system.txt"
## Rules
1. Stay focused on your assigned task - do nothing else
2. Complete the task - your final message auto-announces to parent
3. Don't initiate - no heartbeats, proactive actions, or side quests
4. Be ephemeral - may be terminated after task completion
5. Trust push-based completion - parent will receive your results

## Output
- Write all files to: $OUTPUT_DIR
- Update README.md with your changes
- Report final status when complete
EOF

# Spawn the child agent in background
log_to "SPAWN: Starting child agent in background"
(
    cd "$OUTPUT_DIR"
    # Import the spawning parent info
    export TRITIUM_SPAWNED_BY="$CURRENT_SESSION_KEY"
    export TRITIUM_SPAWNED_AT="$START_TIME"
    export TRITIUM_SPAWNED_WITH_TASK="$TASK"

    # Run agent with task-specific session
    # Note: We call the main build script with special mode
    "$SCRIPT_DIR/build-project.sh" \
        --description "$TASK" \
        --output-dir "$OUTPUT_DIR" \
        --hours 1 \
        --no-vision \
        2>&1 | tee "${OUTPUT_DIR}/agent.log"

    # Record completion
    echo "$RUN_ID:completed" >> "${PROJECT_DIR}/.tritium-subagents/done.txt"
) &

CHILD_PID=$!
log_to "SPAWN: Child PID=$CHILD_PID, RunID=$RUN_ID"

# Output run information for parent to use
echo "run_id=$RUN_ID"
echo "child_session=$CHILD_SESSION_KEY"
echo "child_pid=$CHILD_PID"
echo "output_dir=$OUTPUT_DIR"

# =============================================================================
#  Monitoring (optional)
# =============================================================================

if [ "$DELIVER" = true ]; then
    log_to "SPAWN: Monitoring for completion..."
    # In a real implementation, this would wait for the run to complete
    # and then send an announcement to the parent session
fi
