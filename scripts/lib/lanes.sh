#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Lane/Concurrency System
# =============================================================================
# Lanesserialize agent runs to prevent races:
#   main    - Main auto-reply workflow (user-facing)
#   cron    - Cron job runs (scheduled tasks)
#   subagent - Sub-agent runs (spawning tasks)
#   nested  - Nested/deferred tasks
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lane configuration
MAX_CONCURRENT_MAIN="${MAX_CONCURRENT_MAIN:-3}"
MAX_CONCURRENT_CRON="${MAX_CONCURRENT_CRON:-1}"
MAX_CONCURRENT_SUBAGENT="${MAX_CONCURRENT_SUBAGENT:-2}"
MAX_CONCURRENT_NESTED="${MAX_CONCURRENT_NESTED:-1}"

# Lane directories for queue management
LANE_DIR="${PROJECT_DIR}/.tritium-lanes"

# =============================================================================
#  Lane Operations
# =============================================================================

# Initialize lane directories
init_lanes() {
    mkdir -p "$LANE_DIR"
    mkdir -p "$LANE_DIR/main"
    mkdir -p "$LANE_DIR/cron"
    mkdir -p "$LANE_DIR/subagent"
    mkdir -p "$LANE_DIR/nested"
    # log_to "LANES: Initialized lane directories"  # May not have log_to available when sourced standalone
}

# Get current lane count for a lane type
get_lane_count() {
    local lane_type="$1"
    [ -d "$LANE_DIR/$lane_type" ] && find "$LANE_DIR/$lane_type" -type f | wc -l || echo "0"
}

# Check if lane has capacity
can_run_in_lane() {
    local lane_type="$1"
    local max_concurrent="$2"

    local count
    count=$(get_lane_count "$lane_type")

    [ "$count" -lt "$max_concurrent" ]
}

# Acquire lane slot (returns slot ID or empty on failure)
acquire_lane_slot() {
    local lane_type="$1"
    local max_concurrent="${2:-$MAX_CONCURRENT_MAIN}"

    if can_run_in_lane "$lane_type" "$max_concurrent"; then
        local slot_id="slot-$(date +%s)-$RANDOM"
        touch "$LANE_DIR/$lane_type/$slot_id"
        echo "$slot_id"
    else
        echo ""
    fi
}

# Release lane slot
release_lane_slot() {
    local lane_type="$1"
    local slot_id="$2"
    rm -f "$LANE_DIR/$lane_type/$slot_id" 2>/dev/null || true
}

# Wait for lane capacity (blocks until slot available)
wait_for_lane() {
    local lane_type="$1"
    local max_concurrent="${2:-$MAX_CONCURRENT_MAIN}"
    local timeout="${3:-60}"

    local waited=0
    while ! can_run_in_lane "$lane_type" "$max_concurrent"; do
        if [ "$waited" -ge "$timeout" ]; then
            # log_warn "LANE: Timeout waiting for $lane_type lane"  # May not have log_warn available
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo "Lane available after ${waited}s wait"
}

# =============================================================================
#  Queue Mode Operations
# =============================================================================

# Queue modes for task management
QUEUE_MODE_STEER="steer"        # Immediate execution
QUEUE_MODE_FOLLOWUP="followup"  # Queued followup
QUEUE_MODE_COLLECT="collect"    # Collect for batch processing
QUEUE_MODE_QUEUE="queue"        # Queue for processing

# Queue settings file
QUEUE_SETTINGS_FILE="${PROJECT_DIR}/.tritium-queue/settings.json"

init_queue() {
    mkdir -p "$LANE_DIR/queue"
    mkdir -p "$(dirname "$QUEUE_SETTINGS_FILE")"
    cat > "$QUEUE_SETTINGS_FILE" << EOF
{
  "mode": "$QUEUE_MODE_STEER",
  "debounce_ms": 5000,
  "cap": 10,
  "drop_policy": "old"
}
EOF
    # log_to "QUEUE: Initialized"  # May not have log_to available when sourced standalone
}

get_queue_mode() {
    if [ -f "$QUEUE_SETTINGS_FILE" ]; then
        python3 -c "import json; print(json.load(open('$QUEUE_SETTINGS_FILE')).get('mode', 'steer'))" 2>/dev/null || echo "steer"
    else
        echo "steer"
    fi
}

queue_task() {
    local lane_type="$1"
    local task_data="$2"
    local task_id="task-$(generate_uuid)"

    # Add to queue directory
    echo "$task_data" > "$LANE_DIR/queue/${task_id}.json"

    # log_to "QUEUE: Task queued: $task_id in $lane_type lane"  # May not have log_to available
    echo "$task_id"
}

process_queue() {
    local lane_type="$1"

    for task_file in "$LANE_DIR/queue"/*.json; do
        [ -f "$task_file" ] || continue
        local task_data
        task_data=$(cat "$task_file")

        # Try to acquire lane slot
        local slot
        slot=$(acquire_lane_slot "$lane_type")

        if [ -n "$slot" ]; then
            # log_to "QUEUE: Processing queued task"  # May not have log_to available
            # Process task...
            rm "$task_file"
            release_lane_slot "$lane_type" "$slot"
        else
            # log_to "QUEUE: Lane full, waiting..."  # May not have log_to available
            wait_for_lane "$lane_type"
        fi
    done
}

# =============================================================================
#  Concurrency Control (File Locking)
# =============================================================================

# File-based concurrency control using flock
run_with_lock() {
    local lock_file="$1"
    local max_wait="${2:-300}"

    exec 200>"$lock_file"
    local acquired
    acquired=$(timeout "$max_wait" flock -w "$max_wait" 200)

    if [ $? -eq 0 ]; then
        trap "flock -u 200" EXIT
        "$@"
        flock -u 200
        trap - EXIT
    else
        log_warn "LOCK: Could not acquire lock after ${max_wait}s"
        return 1
    fi
}

# =============================================================================
#  Lane Constants (exported for other scripts)
# =============================================================================

export LANE_MAIN="main"
export LANE_CRON="cron"
export LANE_SUBAGENT="subagent"
export LANE_NESTED="nested"

export MAX_CONCURRENT_MAIN
export MAX_CONCURRENT_CRON
export MAX_CONCURRENT_SUBAGENT
export MAX_CONCURRENT_NESTED

# Initialize on source
init_lanes
