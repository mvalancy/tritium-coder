#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Session Persistence Library
# =============================================================================

# Session state is persisted in ${OUTPUT_DIR}/.tritium-session.json
# Allows resuming interrupted iterations with full state restoration

SESSION_FILE="${OUTPUT_DIR}/.tritium-session.json"

# Save current session state
save_session() {
    cat > "$SESSION_FILE" << EOF
{
  "project_type": "${PROJECT_TYPE:-unknown}",
  "description": "${DESCRIPTION//\"/\\\"}",
  "cycle_count": ${CYCLE:-0},
  "last_health": "${HEALTH_STATUS:-unknown}",
  "last_phase": "${PHASE:-unknown}",
  "cycle_history": [$(echo "$CYCLE_HISTORY" | tail -10 | while IFS= read -r line; do
    [ -n "$line" ] && echo "    \"$line\","
  done | sed '$ s/,$//')],
  "phase_scores": {$(echo "$PHASE_SCORES" | tail -10 | while IFS=: read -r phase score; do
    [ -n "$phase" ] && echo "    \"$phase\": $score,"
  done | sed '$ s/,$//')},
  "total_elapsed_secs": $(elapsed_secs)
}
EOF
    log_to "SESSION saved to ${SESSION_FILE}"
}

# Load session state from file
load_session() {
    if [ ! -f "$SESSION_FILE" ]; then
        log_warn "No session file found at ${SESSION_FILE}"
        return 1
    fi

    # Parse JSON and extract values using Python
    local last_cycle last_health last_phase
    last_cycle=$(python3 -c "import json; d=json.load(open('$SESSION_FILE')); print(d.get('cycle_count', 0))" 2>/dev/null || echo "0")
    last_health=$(python3 -c "import json; d=json.load(open('$SESSION_FILE')); print(d.get('last_health', 'unknown'))" 2>/dev/null || echo "unknown")

    log_ok "SESSION restored: ${last_cycle} cycles completed"
    log_info "Last health: ${last_health}"

    # Note: We don't auto-restore cycle history due to complexity of parsing
    # Users should provide context via --resume or manually resume
    return 0
}

# Check if a session file exists
has_session() {
    [ -f "$SESSION_FILE" ]
}
