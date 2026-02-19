#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Cron Job Scheduling System
# =============================================================================
# Cron scheduling with support for:
#   - at: One-shot execution at specific time
#   - every: Interval-based scheduling
#   - cron: POSIX cron expressions
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cron registry file
CRON_REGISTRY_FILE="${PROJECT_DIR}/.tritium-cron/jobs.json"
CRON_STATE_FILE="${PROJECT_DIR}/.tritium-cron/state.json"

# =============================================================================
#  Cron Structures
# =============================================================================

# Cron schedule types:
#   at: "2026-02-18T09:00:00Z"
#   every: 300 (5 minutes in seconds)
#   cron: "0 * * * *" (POSIX cron)

# Cron payload types:
#   systemEvent: Text to send as system event
#   agentTurn: Full agent turn with message, model, etc.

# Cron delivery modes:
#   none: No delivery
#   announce: Send announcement
#   webhook: Send to webhook URL

# =============================================================================
#  Cron Service
# =============================================================================

# Initialize cron system
cron_init() {
    mkdir -p "$(dirname "$CRON_REGISTRY_FILE")"
    mkdir -p "$(dirname "$CRON_STATE_FILE")"

    # Default state
    cat > "$CRON_STATE_FILE" << EOF
{
  "lastRunAt": 0,
  "nextRunAt": null,
  "suspended": false
}
EOF

    log_to "CRON: Initialized"
}

# Add a cron job
cron_add() {
    local name="$1"
    local schedule_type="$2"
    local schedule_value="$3"
    local payload_kind="${4:-systemEvent}"
    local payload_text="${5:-}"

    local job_id="job-$(generate_uuid)"
    local now=$(date +%s)

    # Initialize registry if needed
    [ ! -f "$CRON_REGISTRY_FILE" ] && cron_init

    python3 << PYTHON_EOF
import json
import os
from datetime import datetime

registry = {"version": 1, "jobs": {}}
try:
    with open("$CRON_REGISTRY_FILE", "r") as f:
        registry = json.load(f)
except: pass

# Parse schedule
schedule = {"kind": "$schedule_type", "$schedule_type": "$schedule_value"}

# Create job
job_id = "$job_id"
registry["jobs"][job_id] = {
    "id": job_id,
    "name": "$name",
    "enabled": True,
    "schedule": schedule,
    "payload": {
        "kind": "$payload_kind",
        "text": "$payload_text"
    },
    "createdAtMs": $now * 1000,
    "updatedAtMs": $now * 1000,
    "nextRunAt": None
}

with open("$CRON_REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)

print(job_id)
PYTHON_EOF
}

# Update a cron job
cron_update() {
    local job_id="$1"
    local patch_file="$2"

    python3 << PYTHON_EOF
import json

with open("$CRON_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

with open("$patch_file", "r") as f:
    patch = json.load(f)

if "$job_id" in registry.get("jobs", {}):
    job = registry["jobs"]["$job_id"]
    for key, value in patch.items():
        job[key] = value
    job["updatedAtMs"] = $(_date +%s) * 1000
    registry["jobs"]["$job_id"] = job

with open("$CRON_REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)
PYTHON_EOF
}

# Remove a cron job
cron_remove() {
    local job_id="$1"

    python3 << PYTHON_EOF
import json
with open("$CRON_REGISTRY_FILE", "r") as f:
    registry = json.load(f)
registry["jobs"].pop("$job_id", None)
with open("$CRON_REGISTRY_FILE", "w") as f:
    json.dump(registry, f, indent=2)
PYTHON_EOF
}

# List cron jobs
cron_list() {
    [ ! -f "$CRON_REGISTRY_FILE" ] && return

    python3 << PYTHON_EOF
import json
from datetime import datetime

with open("$CRON_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

print("CRON JOBS:")
print("-" * 60)
for job_id, job in registry.get("jobs", {}).items():
    status = "enabled" if job.get("enabled", False) else "disabled"
    schedule = job.get("schedule", {})
    print(f"  {job_id}: {job.get('name', 'unnamed')} ({status})")
    print(f"    Schedule: {schedule}")
    print(f"    Created: {datetime.fromtimestamp(job.get('createdAtMs', 0) / 1000)}")
    print()
PYTHON_EOF
}

# Get next due job
cron_get_due() {
    local now
    now=$(date +%s)

    [ ! -f "$CRON_REGISTRY_FILE" ] && return

    python3 << PYTHON_EOF
import json
from datetime import datetime

with open("$CRON_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

now_ms = $now * 1000

for job_id, job in registry.get("jobs", {}).items():
    if not job.get("enabled", False):
        continue

    schedule = job.get("schedule", {})
    kind = schedule.get("kind")

    # Check if job is due
    if kind == "at":
        at_ms = int(datetime.fromisoformat(schedule.get("at", "2000-01-01")).timestamp() * 1000)
        if at_ms <= now_ms:
            print(job_id)
            break
    elif kind == "every":
        interval_sec = int(schedule.get("every", 300))
        created_ms = job.get("createdAtMs", now_ms)
        if (now_ms - created_ms) % (interval_sec * 1000) == 0:
            print(job_id)
            break
    elif kind == "cron":
        # Simplified cron check - in production would use python-crontab
        cron_expr = schedule.get("cron", "")
        print(f"CRON:{cron_expr}:{job_id}")
        break
PYTHON_EOF
}

# Run a cron job
cron_run() {
    local job_id="$1"
    local mode="${2:-force}"

    local job_file="/tmp/cron-job-$$.json"
    python3 << PYTHON_EOF
import json

with open("$CRON_REGISTRY_FILE", "r") as f:
    registry = json.load(f)

job = registry["jobs"]["$job_id"]

payload = job.get("payload", {})
print(json.dumps({
    "job_id": "$job_id",
    "payload": payload,
    "schedule": job.get("schedule", {})
}))
PYTHON_EOF
}

# Suspend cron jobs
cron_suspend() {
    [ ! -f "$CRON_STATE_FILE" ] && return

    python3 << PYTHON_EOF
import json
with open("$CRON_STATE_FILE", "r") as f:
    state = json.load(f)
state["suspended"] = True
with open("$CRON_STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_EOF
}

# Resume cron jobs
cron_resume() {
    [ ! -f "$CRON_STATE_FILE" ] && return

    python3 << PYTHON_EOF
import json
with open("$CRON_STATE_FILE", "r") as f:
    state = json.load(f)
state["suspended"] = False
with open("$CRON_STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_EOF
}

# =============================================================================
#  Cron CLI
# =============================================================================

case "${1:-}" in
    init)
        cron_init
        ;;
    add)
        cron_add "$2" "$3" "$4" "${5:-systemEvent}" "${6:-}"
        ;;
    update)
        cron_update "$2" "$3"
        ;;
    remove)
        cron_remove "$2"
        ;;
    list)
        cron_list
        ;;
    run)
        cron_run "$2" "${3:-force}"
        ;;
    suspend)
        cron_suspend
        ;;
    resume)
        cron_resume
        ;;
    *)
        echo "Usage: $0 {init|add|update|remove|list|run|suspend|resume}"
        exit 1
        ;;
esac
