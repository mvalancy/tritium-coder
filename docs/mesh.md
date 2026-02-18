# Agent Mesh Setup

*(c) 2026 Matthew Valancy | Valpatel Software*

Scale Tritium Coder across multiple machines using Tailscale. Each machine runs Ollama with specialized models; the primary node runs the iteration engine and coordinates everything.

## Overview

```mermaid
flowchart TB
    User["You"] --> Primary["Primary Node<br/>Iteration Engine<br/>Qwen3-Coder-Next"]

    Primary -->|Tailscale| NA["Node A<br/>Vision Model<br/>(screenshot analysis, UI review)"]
    Primary -->|Tailscale| NB["Node B<br/>Fast Coder<br/>(quick edits, completions)"]
    Primary -->|Tailscale| NC["Node C<br/>Embeddings<br/>(code search, RAG)"]

    style User fill:#1a1a2e,stroke:#00d4ff,color:#e0e0e0,stroke-width:2px
    style Primary fill:#0d1b2a,stroke:#7c3aed,color:#e0e0e0,stroke-width:2px
    style NA fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style NB fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style NC fill:#1b2838,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
```

## Hardware Examples

| Role | Model | Hardware | RAM Needed | Purpose |
|------|-------|----------|-----------|---------|
| **Primary thinker** | Qwen3-Coder-Next 80B | GB10 | 128 GB | Planning, complex code, debugging |
| **Fast coder** | Qwen2.5-Coder 7B | Orin AGX / RTX | 16 GB | Quick edits, completions, test generation |
| **Vision** | LLaVA-Next 34B | GB10 / Orin | 32 GB | Screenshot analysis, UI review |
| **Embeddings** | nomic-embed-text | Any CPU | 2 GB | Code search, RAG indexing |

## Setup

### 1. Set up the primary node

Follow the standard install:

```bash
git clone https://github.com/mvalancy/tritium-coder.git
cd tritium-coder
./install.sh
./start
```

### 2. Set up a mesh node

On each additional machine (must be on your Tailscale network):

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull the model for this node's role
ollama pull qwen2.5-coder:7b    # fast coder
# or: ollama pull llava-next     # vision
# or: ollama pull nomic-embed-text  # embeddings

# Verify it's running
curl http://localhost:11434/api/tags
```

That's it for the mesh node. No other software needed.

### 3. Point the iteration engine at mesh nodes

Set environment variables to route vision or fast-coder calls to mesh nodes:

```bash
# In your shell or .tritium.env:
VISION_OLLAMA_URL=http://<tailscale-ip-of-node-a>:11434
```

### 4. Verify connectivity

From the primary node, verify each mesh node is reachable:

```bash
curl http://<tailscale-ip>:11434/api/tags
```

## Network Topology

```mermaid
flowchart LR
    subgraph Tailnet["Your Tailscale Network (private)"]
        P["Primary<br/>100.x.x.1<br/>:11434 :8082"]
        A["Node A<br/>100.x.x.2<br/>:11434"]
        B["Node B<br/>100.x.x.3<br/>:11434"]

        P <-->|"encrypted"| A
        P <-->|"encrypted"| B
    end

    Internet["Public Internet"] -.->|"blocked"| Tailnet

    style Tailnet fill:#0d1b2a,stroke:#7c3aed,color:#e0e0e0,stroke-width:2px
    style P fill:#7c3aed,stroke:#c4b5fd,color:#ffffff,stroke-width:2px
    style A fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style B fill:#1e3a5f,stroke:#06b6d4,color:#e0e0e0,stroke-width:2px
    style Internet fill:#3a1a1a,stroke:#f87171,color:#e0e0e0,stroke-width:2px
```

All traffic between nodes goes over Tailscale's encrypted WireGuard tunnels. No ports are exposed to the public internet.

## Scaling Tips

- **Start small.** One machine is enough for most coding work. Add nodes when you need specialized models.
- **GPU matters more than CPU.** Inference speed is dominated by GPU memory bandwidth.
- **Model size = RAM.** A 7B model needs ~8 GB RAM. A 34B model needs ~24 GB. An 80B MoE model needs ~50 GB.
- **One model per node.** Ollama can serve multiple models, but switching between them flushes GPU memory. Dedicate each node to one role.
- **Tailscale is zero-config.** Once a machine is on your tailnet, it's reachable by IP. No port forwarding, no DNS, no VPN setup.
