# Architecture

*(c) 2026 Matthew Valancy | Valpatel Software*

## Single Machine

The default setup runs everything on one machine. Three services start and stay resident; you interact through the dashboard or terminal agents.

```mermaid
flowchart TB
    subgraph User["User Interfaces"]
        Dashboard["Dashboard\n(browser)"]
        Terminal["Terminal Agent\n(run-openclaw.sh)"]
        Claude["Claude Code\n(run-claude.sh)"]
    end

    subgraph Gateway["OpenClaw Gateway :18789"]
        Chat["Chat / Jobs"]
        Approvals["Exec Approvals"]
        Sessions["Session Manager"]
    end

    subgraph Proxy["claude-code-proxy :8082"]
        Translate["Anthropic API\n→ OpenAI API"]
    end

    subgraph Ollama["Ollama :11434"]
        Model["Qwen3-Coder-Next\n80B MoE"]
    end

    Dashboard --> Gateway
    Terminal --> Gateway
    Claude --> Proxy
    Proxy --> Ollama
    Gateway --> Ollama
```

## Request Flow

How a coding job flows through the system, from user prompt to generated code.

```mermaid
sequenceDiagram
    participant U as User
    participant G as Gateway
    participant O as Ollama
    participant FS as Filesystem

    U->>G: Send coding task
    G->>O: Forward prompt + tools
    O-->>G: Tool call (read_file)
    G->>FS: Read file
    FS-->>G: File contents
    G->>O: Tool result
    O-->>G: Tool call (write_file)
    G->>FS: Write file
    FS-->>G: OK
    O-->>G: Tool call (execute_command)
    G->>G: Check exec allowlist
    G->>FS: Execute command
    FS-->>G: Command output
    G->>O: Tool result
    O-->>G: Final response
    G-->>U: Done — files written
```

## Claude Code Path

Claude Code uses the proxy to translate Anthropic's Messages API to OpenAI's Chat Completions API, which Ollama speaks natively.

```mermaid
flowchart LR
    CC["Claude Code CLI"]
    P["claude-code-proxy\n:8082"]
    O["Ollama\n:11434"]
    M["Qwen3-Coder-Next"]

    CC -->|"Anthropic\nMessages API"| P
    P -->|"OpenAI\nChat API"| O
    O --> M
```

## Agent Mesh

Multiple machines on a Tailscale network form a mesh. The primary node runs the gateway and the main thinking model. Mesh nodes run specialized models and are registered as additional providers.

```mermaid
flowchart TB
    subgraph Primary["Primary Node"]
        GW["OpenClaw Gateway"]
        O1["Ollama"]
        M1["Qwen3-Coder-Next\n(thinking)"]
        O1 --> M1
        GW --> O1
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

    subgraph NodeC["Mesh Node C"]
        O4["Ollama"]
        M4["Embeddings"]
        O4 --> M4
    end

    GW -->|Tailscale| O2
    GW -->|Tailscale| O3
    GW -->|Tailscale| O4
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

    subgraph Gateway["OpenClaw Gateway"]
        direction TB
        B1["Session management"]
        B2["Exec approval workflow"]
        B3["Tool policy enforcement"]
        B4["Dashboard web UI"]
        B5["Cron scheduling"]
    end

    subgraph Proxy["claude-code-proxy"]
        direction TB
        C1["API format translation"]
        C2["Model name mapping"]
        C3["Streaming support"]
    end
```
