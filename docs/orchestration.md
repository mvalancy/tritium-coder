# Tritium Coder - Agentic Orchestration Pattern

This document describes the agentic orchestration system implemented in Tritium Coder, inspired by OpenClaw's patterns.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Interface Layer                         │
│   (./iterate command, dashboard, logs)                             │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────────────┐
│                  Main Agent Session                                  │
│   - Session ID tracking                                             │
│   - State persistence                                               │
│   - Phase selection                                                 │
│   - Error recovery                                                  │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
┌────────▼──────┐┌─────▼──────┐┌─────▼──────────┐
│ Health Check ││ Code Gen   ││ Vision Gate    │
│ (Type-Aware) ││ (Type-Aware││ (Multi-        │
│              ││  Prompts)  ││  Resolution)   │
└──────────────┘└────────────┘└────────────────┘
         │             │             │
         └─────────────┴─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │    Project Output         │
         │    - index.html / .py     │
         │    - tests/              │
         │    - docs/               │
         │    - README.md           │
         └───────────────────────────┘
```

## Project Types

The system detects and handles multiple project types:

| Type | Description | Detection Keywords |
|------|-------------|-------------------|
| `web-game` | HTML5 Canvas games, Tetris, Pong | game, tetris, pong, canvas, arcade, play, level, score, sprite |
| `web-app` | Web applications, dashboards, forms | web app, dashboard, form, interface, page, website, site, portal |
| `api` | REST/GraphQL APIs, backend services | api, rest, backend, server, flask, fastapi, express |
| `cli` | Command-line tools, scripts, utilities | cli, command-line, terminal, script, shell script, command-line tool |
| `library` | Reusable modules, packages, utilities | library, module, package, reusable, utility, helper |
| `self` | Project self-modification, maintainance | The project directory itself |

## Phase Selection

The system uses dynamic phase selection based on:

1. **Health Status**: FAIL → fix, WARN → fix, PASS → improve/polish
2. **Maturity Tier**: early (cycles 1-3) → fix/improve/test/features, mid (4-10) → polish/docs, late (11+) → consolidate/refactor
3. **File Size**: Large files → refactor
4. **Project Type**: Type-specific optimal phases

## Error Analysis

The system categorizes errors for actionable fixes:

| Category | Description | Suggested Fix |
|----------|-------------|---------------|
| `network_error` | 404s, missing resources | Create missing files, fix paths |
| `reference_error` | undefined variables/functions | Initialize before use, check names |
| `type_error` | null/undefined access | Add null checks, verify selectors |
| `syntax_error` | Parsing errors | Check brackets, quotes, semicolons |
| `other` | Runtime/compatibility issues | Review error logs |

## Session Persistence

Session state is saved after each cycle to `${OUTPUT_DIR}/.tritium-session.json`:
- Project type
- Description
- Cycle count
- Health status
- Phase history
- Phase scores
- Total elapsed time

## Security Model

See `config/security.json` for:
- Allowed tools (read, write, bash, glob, grep, http_get, http_post)
- Denied commands (sudo, rm -rf, etc.)
- Path restrictions
- Audit logging

## Audit Logging

All actions are logged to `${PROJECT_DIR}/logs/tritium-audit.jsonl` with:
- Timestamp
- Cycle number
- Phase
- Result
- Duration
