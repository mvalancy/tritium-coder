#!/usr/bin/env bash
# =============================================================================
#  Tritium Coder  |  Project Type Detection
# =============================================================================

# Detect project type from description and existing files
detect_project_type() {
    local desc="$1"
    local output_dir="$2"
    local file_count=0
    local has_html=0 has_js=0 has_css=0 has_package_json=0 has_requirements=0
    local has_index_js=0 has_main_py=0

    # Count existing source files
    if [ -d "$output_dir" ]; then
        file_count=$(find "$output_dir" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.py' -o -name '*.ts' -o -name '*.go' -o -name '*.rs' \) 2>/dev/null | wc -l)
    fi

    # Check for specific file patterns
    [ -f "$output_dir/index.html" ] && has_html=1
    [ -f "$output_dir/index.js" ] && has_index_js=1
    [ -f "$output_dir/main.py" ] && has_main_py=1
    [ -f "$output_dir/requirements.txt" ] && has_requirements=1
    [ -f "$output_dir/package.json" ] && has_package_json=1

    # Check description keywords
    local desc_lower
    desc_lower=$(echo "$desc" | tr '[:upper:]' '[:lower:]')

    # Priority-based detection
    # 1. Self-modification (highest priority)
    if [ "$output_dir" = "$PROJECT_DIR" ] || [ "$output_dir" = "${PROJECT_DIR}/." ]; then
        echo "self"
        return
    fi

    # 2. web-game: explicitly mentions game, HTML5 canvas, or has index.html with game-like keywords
    # If game keywords present, prioritize web-game (even if no files yet)
    if echo "$desc_lower" | grep -qE "(game|tetris|pong|canvas|arcade|play|level|score|sprite)"; then
        echo "web-game"
        return
    fi

    # 4. api: API, REST, backend, server, flask, express, node, etc.
    # Check API first since "ui" is in "api" and would match web-app
    if echo "$desc_lower" | grep -qE "(api|rest|backend|server|flask|fastapi|express)" || \
       [ -f "$output_dir/app.py" ] || [ -f "$output_dir/server.js" ]; then
        # If keywords present, assume api unless contradicted by other signals
        echo "api"
        return
    fi

    # 3. web-app: web app, dashboard, form, UI, etc.
    if echo "$desc_lower" | grep -qE "(web app|dashboard|form|interface|page|website|site|portal)"; then
        echo "web-app"
        return
    fi

    # 6. library: library, module, package, reusable, etc.
    # Check library before cli since "library" is a strong indicator
    if echo "$desc_lower" | grep -qE "(library|module|package|reusable|utility|helper)"; then
        echo "library"
        return
    fi

    # 5. cli: command-line, cli, tool, script, terminal, etc.
    if echo "$desc_lower" | grep -qE "(cli|command-line|command line|terminal|script|shell script)" || \
       [ -f "$output_dir/main.py" ] || [ -f "$output_dir/$PROJECT_NAME" ]; then
        # If keywords present, assume cli unless contradicted by other signals
        echo "cli"
        return
    fi

    # 7. Default based on file presence
    if [ $has_html -eq 1 ]; then
        echo "web-app"
        return
    fi
    if [ $has_requirements -eq 1 ] || [ $has_main_py -eq 1 ]; then
        # Check if it looks like an API or CLI
        if [ $has_index_js -eq 1 ]; then
            echo "api"
            return
        fi
        if [ -f "$output_dir/main.py" ]; then
            echo "cli"
            return
        fi
    fi
    if [ -f "$output_dir/package.json" ]; then
        echo "api"
        return
    fi

    # 8. Fallback: detect from description
    if echo "$desc_lower" | grep -qE "(website|web page|site|html|css|javascript)"; then
        echo "web-app"
        return
    fi
    if echo "$desc_lower" | grep -qE "(python|python3)"; then
        if echo "$desc_lower" | grep -qE "(command-line|terminal|cli)"; then
            echo "cli"
        else
            echo "api"
        fi
        return
    fi

    # 9. Ultimate fallback
    echo "web-app"
}

# Update global PROJECT_TYPE variable
update_project_type() {
    PROJECT_TYPE=$(detect_project_type "$DESCRIPTION" "$OUTPUT_DIR")
    log_to "PROJECT_TYPE={PROJECT_TYPE}"
}
