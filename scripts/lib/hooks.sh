#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Hook/Event System
# =============================================================================
# System for event-driven automation via hooks:
#   - command:*  - Command execution (/new, /reset, /stop)
#   - session:*  - Session lifecycle (create, delete, reset)
#   - agent:*    - Agent lifecycle (bootstrap, start, end)
#   - gateway:*  - Gateway events (connect, disconnect)
#   - message:*  - Message events (received, sent)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Hook discovery directories
HOOK_DIRS=(
    "${SCRIPT_DIR}/hooks"
    "${PROJECT_DIR}/.tritium/hooks"
)

# Hook registry
HOOK_REGISTRY_FILE="${PROJECT_DIR}/.tritium-hooks/registry.json"

# =============================================================================
#  Hook Types and Actions
# =============================================================================

# Hook event types
HOOK_COMMAND="command"
HOOK_SESSION="session"
HOOK_AGENT="agent"
HOOK_GATEWAY="gateway"
HOOK_MESSAGE="message"

# Command hooks
HOOK_COMMAND_NEW="command:new"
HOOK_COMMAND_RESET="command:reset"
HOOK_COMMAND_STOP="command:stop"

# Session hooks
HOOK_SESSION_CREATE="session:create"
HOOK_SESSION_DELETE="session:delete"
HOOK_SESSION_RESET="session:reset"

# Agent hooks
HOOK_AGENT_BOOTSTRAP="agent:bootstrap"
HOOK_AGENT_START="agent:start"
HOOK_AGENT_END="agent:end"

# Gateway hooks
HOOK_GATEWAY_STARTUP="gateway:startup"
HOOK_GATEWAY_SHUTDOWN="gateway:shutdown"

# Message hooks
HOOK_MESSAGE_RECEIVED="message:received"
HOOK_MESSAGE_SENT="message:sent"

# =============================================================================
#  Hook Discovery
# =============================================================================

# Find all hook files
find_hooks() {
    for dir in "${HOOK_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            find "$dir" -name "*.sh" -type f 2>/dev/null
        fi
    done
}

# Parse hook metadata from file (YAML frontmatter)
parse_hook_meta() {
    local hook_file="$1"
    # Extract metadata between --- markers
    sed -n '2,/^\.\.\./p' "$hook_file" 2>/dev/null | grep -E "^[a-z]+:" | sed 's/://' | tr -d ' '
    # Return: name, description, enabled, etc.
}

# =============================================================================
#  Hook Registry
# =============================================================================

init_hook_registry() {
    mkdir -p "$(dirname "$HOOK_REGISTRY_FILE")"
    cat > "$HOOK_REGISTRY_FILE" << EOF
{
  "version": 1,
  "hooks": {}
}
EOF
}

# Register a hook
register_hook() {
    local hook_name="$1"
    local hook_file="$2"
    local hook_enabled="${3:-true}"
    local hook_description="${4:-}"

    # Initialize if not exists
    [ ! -f "$HOOK_REGISTRY_FILE" ] && init_hook_registry

    python3 << PYTHON_EOF
import json
with open("$HOOK_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

registry["hooks"]["$hook_name"] = {
    "file": "$hook_file",
    "enabled": $hook_enabled,
    "description": "$hook_description",
    "registeredAt": $(_date +%s)
}

with open("$HOOK_REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)
PYTHON_EOF
}

# Get registered hooks
list_hooks() {
    [ ! -f "$HOOK_REGISTRY_FILE" ] && return

    python3 << PYTHON_EOF
import json
with open("$HOOK_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

for name, hook in registry.get("hooks", {}).items():
    status = "enabled" if hook.get("enabled", False) else "disabled"
    print(f"  {name}: {status}")
    print(f"    File: {hook.get('file', '')}")
    print(f"    Description: {hook.get('description', '')}")
    print()
PYTHON_EOF
}

# =============================================================================
#  Hook Execution
# =============================================================================

# Trigger a hook
trigger_hook() {
    local hook_type="$1"
    local action="$2"
    local context="${3:-}"

    if [ -z "$context" ]; then
        context="{}"
    fi

    # Build event object
    local event_file="/tmp/tritium-hook-event-$$.json"
    python3 << PYTHON_EOF
import json
event = {
    "type": "$hook_type",
    "action": "$action",
    "timestamp": $(_date +%s),
    "context": json.loads('''$context'''),
    "messages": []
}

with open("$event_file", "w") as f:
    json.dump(event, f, indent=2)
PYTHON_EOF

    # Find and execute hooks for this event
    local hook_event_key="${hook_type}:${action}"

    for hook_file in $(find_hooks); do
        local meta
        meta=$(parse_hook_meta "$hook_file")

        # Check if hook handles this event
        if echo "$meta" | grep -q "actions"; then
            log_to "HOOK: Triggering $hook_file for $hook_event_key"
            # Trigger hook (hook file should handle $event_file)
            source "$hook_file" "$event_file" 2>/dev/null || true
        fi
    done

    # Clean up
    rm -f "$event_file" 2>/dev/null
}

# =============================================================================
#  Internal Hook API
# =============================================================================

# Register an internal hook handler
register_internal_hook() {
    local hook_name="$1"
    local handler="$2"

    # Store handler in registry
    local handlers_dir="${PROJECT_DIR}/.tritium-hooks/handlers"
    mkdir -p "$handlers_dir"
    echo "$handler" > "$handlers_dir/${hook_name//:/_}.sh"
}

# Trigger an internal hook
trigger_internal_hook() {
    local event_file="$1"

    [ ! -f "$event_file" ] && return

    local hook_type action
    hook_type=$(python3 -c "import json; print(json.load(open('$event_file')).get('type', ''))")
    action=$(python3 -c "import json; print(json.load(open('$event_file')).get('action', ''))")

    # Find matching handler
    local handlers_dir="${PROJECT_DIR}/.tritium-hooks/handlers"
    local handler_file="${handlers_dir}/${hook_type}_${action}.sh"

    if [ -f "$handler_file" ]; then
        log_to "HOOK: Executing handler: $handler_file"
        source "$handler_file" "$event_file"
    fi
}

# =============================================================================
#  Lifecycle Hooks
# =============================================================================

# Call on agent bootstrap
on_agent_bootstrap() {
    local session_key="$1"
    local workspace_dir="${2:-.}"

    local context="{\"sessionKey\": \"$session_key\", \"workspaceDir\": \"$workspace_dir\"}"
    trigger_hook "agent" "bootstrap" "$context"
}

# Call on agent start
on_agent_start() {
    local session_key="$1"
    local task="$2"

    local context="{\"sessionKey\": \"$session_key\", \"task\": \"$task\"}"
    trigger_hook "agent" "start" "$context"
}

# Call on agent end
on_agent_end() {
    local session_key="$1"
    local status="${2:-success}"
    local duration="${3:-0}"

    local context="{\"sessionKey\": \"$session_key\", \"status\": \"$status\", \"duration\": $duration}"
    trigger_hook "agent" "end" "$context"
}

# =============================================================================
#  Hook Management CLI
# =============================================================================

case "${1:-}" in
    list)
        list_hooks
        ;;
    register)
        register_hook "$2" "$3" "${4:-true}" "${5:-}"
        ;;
    trigger)
        trigger_hook "$2" "$3" "${4:-}"
        ;;
    init)
        init_hook_registry
        ;;
    *)
        echo "Usage: $0 {list|register|trigger|init}"
        exit 1
        ;;
esac
