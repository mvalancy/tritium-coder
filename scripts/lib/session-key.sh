#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Session Key System
# =============================================================================
# Session keys encode hierarchy:
#   agent:<agentId>:main                    - Main session (depth 0)
#   agent:<agentId>:subagent:<uuid>         - First-level sub-agent (depth 1)
#   agent:<agentId>:subagent:<uuid>:subagent:<uuid> - Second-level (depth 2)
# =============================================================================

# Maximum spawn depth (0 = no sub-agents, 1 = one level, 2 = nested)
MAX_SPAWN_DEPTH="${MAX_SPAWN_DEPTH:-1}"

# Agent ID (unique identifier for this agent instance)
TRITIUM_AGENT_ID="${TRITIUM_AGENT_ID:-tritium}"

# Generate a random UUID for session keys
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 &>/dev/null; then
        python3 -c "import uuid; print(str(uuid.uuid4()))"
    else
        # Fallback: timestamp + random hex
        echo "agent-$(date +%s)-$(head -c 16 /dev/urandom 2>/dev/null | xxd -p | head -c 16)"
    fi
}

# Get session key for main session
get_main_session_key() {
    local agent_id="${1:-$TRITIUM_AGENT_ID}"
    echo "agent:${agent_id}:main"
}

# Get session key for sub-agent
get_subagent_session_key() {
    local parent_session_key="$1"
    local task_label="${2:-task}"
    local uuid
    uuid=$(generate_uuid)
    echo "${parent_session_key}:subagent:${uuid}"
}

# Parse session key and return components
# Format: agent:<agentId>[:subagent:<uuid>]*[:main]
parse_session_key() {
    local key="$1"
    # Extract agent ID (second component)
    local agent_id
    agent_id=$(echo "$key" | cut -d: -f2)
    echo "$agent_id"
}

# Get subagent depth from session key
# Returns 0 for main, 1 for subagent, 2 for nested
get_subagent_depth() {
    local key="$1"
    # Count occurrences of 'subagent' in the key
    local count
    count=$(echo "$key" | grep -o "subagent" | wc -l)
    echo "$count"
}

# Check if key is main session
is_main_session() {
    local key="$1"
    [[ "$key" == *"main"* ]] && [[ "$key" != *"subagent"* ]]
}

# Check if key is sub-agent session
is_subagent_session() {
    local key="$1"
    [[ "$key" == *"subagent"* ]]
}

# Get parent session key (remove last subagent segment)
get_parent_session_key() {
    local key="$1"
    # Remove the last :subagent:<uuid> segment
    echo "$key" | sed 's/:subagent:[^:]*$//'
}

# Check if child key is descended from parent
is_descendant_of() {
    local child_key="$1"
    local parent_key="$2"
    # Child must start with parent key
    [[ "$child_key" == "${parent_key}:"* ]]
}

# Generate a unique run ID for tracking
generate_run_id() {
    echo "run-$(date +%s)-$(generate_uuid | head -c 8)"
}
