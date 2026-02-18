# Architecture

*(c) 2026 Matthew Valancy | Valpatel Software*

## Single Machine

The default setup runs everything on one machine. Two services start and stay resident; you interact through the dashboard or terminal.

```mermaid
flowchart TB
    subgraph User["User Interfaces"]
        Dashboard["Dashboard<br/>(browser :18790)"]
        Terminal["Claude Code<br/>(run-claude.sh)"]
        Iterate["Iteration Engine<br/>(./iterate)"]
    end

    subgraph Proxy["claude-code-proxy :8082"]
        Translate["Anthropic API<br/>→ OpenAI API"]
    end

    subgraph Ollama["Ollama :11434"]
        Coder["Qwen3-Coder-Next<br/>80B MoE"]
        Vision["qwen3-vl:32b<br/>vision model"]
    end

    Dashboard -->|"status checks"| Ollama
    Dashboard -->|"status checks"| Proxy
    Terminal --> Proxy
    Iterate --> Proxy
    Proxy --> Ollama

    style User fill:#1a1a2e,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
    style Proxy fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Ollama fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Dashboard fill:#1a1a2e,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
    style Terminal fill:#4c1d95,stroke:#a78bfa,color:#e0e0e0,stroke-width:2px
    style Iterate fill:#7c3aed,stroke:#c4b5fd,color:#ffffff,stroke-width:2px
    style Translate fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Coder fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Vision fill:#0f3460,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
```

## Request Flow

How a coding job flows through the system, from user prompt to generated code.

```mermaid
sequenceDiagram
    participant U as User / Engine
    participant CC as Claude Code
    participant P as Proxy :8082
    participant O as Ollama :11434
    participant FS as Filesystem

    U->>CC: claude -p "prompt"
    CC->>P: Anthropic Messages API
    P->>O: OpenAI Chat API
    O-->>P: Tool call (write_file)
    P-->>CC: Tool call
    CC->>FS: Write file
    FS-->>CC: OK
    CC->>P: Tool result
    P->>O: Continue
    O-->>P: Final response
    P-->>CC: Response
    CC-->>U: Done — files written
```

## Iteration Engine Flow

The perpetual iteration engine (`build-project.sh`) orchestrates the build loop.

```mermaid
flowchart TB
    CLI["./iterate 'Build a game'"]
    Generate["Generate initial code<br/>(Claude Code)"]
    Health["Health Check<br/>(Playwright headless browser)"]
    Select["Phase Selection<br/>(deterministic rules)"]
    Code["Claude Code<br/>(one focused task)"]
    Vision["Vision Gate<br/>(screenshots → vision model)"]
    Done["Done<br/>(time budget exhausted)"]

    CLI --> Generate
    Generate --> Health
    Health --> Select
    Select --> Code
    Code --> Health
    Code -.->|"after polish"| Vision
    Vision -.->|"feedback"| Code
    Health -->|"no time left"| Done

    style CLI fill:#1a1a2e,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
    style Generate fill:#4c1d95,stroke:#a78bfa,color:#e0e0e0,stroke-width:2px
    style Health fill:#064e3b,stroke:#34d399,color:#e0e0e0,stroke-width:2px
    style Select fill:#312e81,stroke:#a78bfa,color:#e0e0e0,stroke-width:2px
    style Code fill:#7c3aed,stroke:#c4b5fd,color:#ffffff,stroke-width:2px
    style Vision fill:#0f3460,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
    style Done fill:#1a1a2e,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
```

## Claude Code Path

Claude Code uses the proxy to translate Anthropic's Messages API to OpenAI's Chat Completions API, which Ollama speaks natively.

```mermaid
flowchart LR
    CC["Claude Code CLI"]
    P["claude-code-proxy<br/>:8082"]
    O["Ollama<br/>:11434"]
    M["Qwen3-Coder-Next"]

    CC -->|"Anthropic<br/>Messages API"| P
    P -->|"OpenAI<br/>Chat API"| O
    O --> M

    style CC fill:#4c1d95,stroke:#a78bfa,color:#e0e0e0,stroke-width:2px
    style P fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style O fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style M fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
```

## Agent Mesh (Experimental)

Multiple machines on a Tailscale network form a mesh. The primary node runs the main model. Mesh nodes run specialized models and are accessed via Tailscale DNS.

```mermaid
flowchart TB
    subgraph Primary["Primary Node"]
        Engine["Iteration Engine"]
        O1["Ollama"]
        M1["Qwen3-Coder-Next<br/>(thinking)"]
        O1 --> M1
        Engine --> O1
    end

    subgraph NodeA["Mesh Node A"]
        O2["Ollama"]
        M2["Vision Model"]
        O2 --> M2
    end

    subgraph NodeB["Mesh Node B"]
        O3["Ollama"]
        M3["Fast Coder"]
        O3 --> M3
    end

    Engine -->|Tailscale| O2
    Engine -->|Tailscale| O3

    style Primary fill:#0d1b2a,stroke:#7c3aed,color:#e0e0e0,stroke-width:2px
    style NodeA fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style NodeB fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Engine fill:#7c3aed,stroke:#c4b5fd,color:#ffffff,stroke-width:2px
    style O1 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style M1 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style O2 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style M2 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style O3 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style M3 fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
```

## Component Responsibilities

```mermaid
flowchart LR
    subgraph Ollama["Ollama"]
        direction TB
        A1["Model download/management"]
        A2["Inference (GPU)"]
        A3["Tool calling dispatch"]
        A4["OpenAI-compatible API"]
    end

    subgraph Engine["Tritium Coder Engine"]
        direction TB
        B1["Iteration orchestration"]
        B2["Health checks (Playwright)"]
        B3["Dynamic phase selection"]
        B4["Vision gate reviews"]
        B5["Session management"]
    end

    subgraph Proxy["claude-code-proxy"]
        direction TB
        C1["API format translation"]
        C2["Model name mapping"]
        C3["Streaming support"]
    end

    style Ollama fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Engine fill:#0d1b2a,stroke:#7c3aed,color:#e0e0e0,stroke-width:2px
    style Proxy fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
```
