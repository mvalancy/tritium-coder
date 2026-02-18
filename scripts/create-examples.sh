#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  Tritium Coder  |  Create Examples
#
#  Feeds project descriptions to build-project.sh one at a time.
#  Each project gets a time budget and starts from an empty directory.
#
#  Usage:  scripts/create-examples.sh [hours-per-project]
#  Default: 4 hours per project
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

HOURS="${1:-4}"

# =============================================================================
#  Project definitions — add/edit these to change what gets built
# =============================================================================

PROJECTS=(
    "tetris"
    "pong"
    "smashtv"
)

declare -A PROMPTS

PROMPTS["tetris"]="Build a complete Tetris web game with HTML5 canvas. \
Piece rotation with wall kicks, ghost piece, hold piece, next piece preview, \
level progression with increasing speed, line clear animations with particles, \
combo scoring, T-spin detection, dark neon theme with glowing pieces, \
procedural sound effects via Web Audio API, pause menu, high scores in localStorage, \
smooth 60fps rendering. Must be fully playable by opening index.html."

PROMPTS["pong"]="Build a complete Pong web game with HTML5 canvas. \
AI opponent with adjustable difficulty, ball speed increases over time, \
particle trails on the ball, screen shake on impact, power-ups (multi-ball, \
wide paddle, slow motion), neon glow effects, score announcements with text popups, \
procedural sound effects via Web Audio API, start menu, pause, game over screen, \
smooth animations. Must be fully playable by opening index.html."

PROMPTS["smashtv"]="Build a complete Smash TV twin-stick arena shooter with HTML5 canvas. \
WASD movement + mouse aiming and shooting, multiple enemy types (runners, shooters, \
tanks, bosses), weapon upgrades (spread shot, laser, rockets), particle explosions, \
screen shake on kills, wave system with increasing difficulty and boss waves, \
power-ups (health, speed boost, shield, weapon upgrades), HUD with score/health/wave/ammo, \
dark sci-fi arena theme, procedural audio via Web Audio API, minimap, \
start screen, pause, game over with stats. Must be fully playable by opening index.html."

# =============================================================================
#  Run
# =============================================================================

banner
section "Create Examples"

echo "  Projects:  ${PROJECTS[*]}"
echo "  Hours/ea:  ${HOURS}"
echo "  Total:     $((HOURS * ${#PROJECTS[@]})) hours max"
echo ""

TOTAL_START=$(date +%s)

for project in "${PROJECTS[@]}"; do
    remaining_projects=$((${#PROJECTS[@]} - $(printf '%s\n' "${PROJECTS[@]}" | grep -n "^${project}$" | cut -d: -f1) + 1))

    echo ""
    section "${project} (${remaining_projects} projects remaining)"

    dir="${PROJECT_DIR}/examples/${project}"
    rm -rf "$dir"
    mkdir -p "$dir"

    log_ok "Starting ${project} (${HOURS}h budget)"

    "$SCRIPT_DIR/build-project.sh" "${PROMPTS[$project]}" \
        --name "$project" \
        --hours "$HOURS" \
        --dir "$dir" \
        2>&1 | tee "$LOG_DIR/example-${project}.log"

    fc=$(find "$dir" -type f 2>/dev/null | wc -l)
    log_ok "${project} complete: ${fc} files"
done

TOTAL_TIME=$(( $(date +%s) - TOTAL_START ))

echo ""
section "All Examples Complete"
echo "  Total time: $((TOTAL_TIME / 60)) minutes"
echo ""

for project in "${PROJECTS[@]}"; do
    dir="${PROJECT_DIR}/examples/${project}"
    fc=$(find "$dir" -type f 2>/dev/null | wc -l)
    sz=$(du -sh "$dir" 2>/dev/null | cut -f1)
    echo "  ${project}: ${fc} files, ${sz}"
done

echo ""
echo "  View: python3 -m http.server 8080 -d examples/tetris"
echo ""
