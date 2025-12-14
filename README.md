# ACN - Autonomous Cognitive Node

> A self-replicating, distributed agent system for autonomous software development on the BEAM VM.

## What Is This?

ACN is not a chatbot. It's not a code assistant. It's an **autonomous organism** that thinks, plans, codes, validates its own work, and spawns copies of itself to divide complex tasks.

Think of it as a digital life form that:
- **Self-initializes** from a single genesis command
- **Self-validates** every action it takes
- **Self-replicates** to tackle complex problems hierarchically  
- **Self-heals** through OTP supervision and stress monitoring
- **Self-secures** via zero-trust JWT authentication

Built on Elixir/OTP, ACN leverages 30+ years of battle-tested distributed systems wisdom from Erlang to create something entirely new: **truly autonomous software agents**.

## Architecture

### The Brain (Cognitive Engine)
- **Controller**: The sovereign authority. Makes all strategic decisions through 4 distinct personas:
  - *Legislator*: Synthesizes conflicting rules into coherent policy
  - *Architect*: Designs precise technical specifications
  - *Judge*: Validates work against policy constraints
  - *Security Officer*: Enforces zero-trust access control
- **SupervisorAgent**: Determines node identity (Leaf/Intermediate), fetches ancestral context via RPC, manages genesis
- **Task Manager**: DAG-based dependency planner with cycle detection

### The Hands (Execution Layer)
- **Actuator**: Zero-trust file operations and command execution. Rejects all requests without valid JWT.
- **Sandbox**: Isolated command execution via Erlang Ports with timeout protection
- **Specialist**: In-memory virtual filesystem for drafting code before committing to disk

### The Eyes (Quality Assurance)
- **Validator**: Three-way handshake QA system (Request Token → Execute → Report Verdict)
- **Synthesizer**: Archives completed work to external memory, triggers graceful shutdown

### The Nervous System
- **LiveWire**: Real-time telemetry and stress monitoring. Tracks pain signals, critical thresholds, system health
- **Messenger**: Internal event bus with authentication and global broadcasting

### Infrastructure
- **NodeRegistry**: Namespaced process registry enabling multiple logical nodes in single VM
- **Router**: Message routing (`:local` for same-node, `:sideways` for peer communication)
- **TokenAuthority**: RSA-2048 JWT minting and verification with scope enforcement
- **ProfileLoader**: YAML-based cognitive profiles for hot-swappable AI personality/rules
- **NodeSupervisor**: DynamicSupervisor for fractal node spawning
- **Lattice**: Distributed Erlang RPC client for inter-node context inheritance

## The Two Workflows

### Leaf Node (Worker)
**Purpose**: Execute atomic tasks (write a function, run a test, edit a file)

**Lifecycle**:
1. **Legislation**: Synthesize local rulebook from ancestors + constraints
2. **Architecture**: Design precise execution plan
3. **Delegation**: Route work to Specialist (LLM integration point)
4. **Policy Review**: Judge validates draft against rules
5. **Security Review**: Officer authorizes disk access
6. **Execution**: Actuator writes to filesystem
7. **Validation**: External tests confirm quality
8. **Finalization**: Synthesizer archives results

### Intermediate Node (Manager)  
**Purpose**: Decompose complex tasks into sub-tasks

**Lifecycle**:
1. **Team Legislation**: Establish coordination rules
2. **Decomposition**: Task Manager breaks down problem
3. **Infrastructure Setup**: Actuator prepares workspace
4. **Child Spawning**: Supervisor creates worker nodes
5. **Monitoring**: Collect results from distributed children

## Fractal Self-Replication

Each node can spawn unlimited children. Children inherit context from parents via RPC. This creates a **living organizational hierarchy**:

```
Root Node (Manager)
├─ Foundation Team (Manager)
│  ├─ Foundation Worker 1
│  ├─ Foundation Worker 2
│  └─ Foundation Worker 3
├─ Walls Team (Manager)
│  ├─ Wall Worker 1
│  └─ Wall Worker 2
└─ Roof Team (Manager)
   └─ Roof Worker 1
```

The system stops spawning when tasks are atomic. It's **Conway's Law as executable code**.

## Security Model

**Zero Trust, Always**:
- Controller holds private key (generated on boot)
- All sensitive operations require JWT signed by Controller
- Actuator verifies token signature + scope before executing
- Tokens are single-use, operation-specific
- No operation bypasses the permission loop

**The Ring of Trust**:
1. Validator requests token from Controller
2. Controller mints JWT for specific operation
3. Validator receives token
4. Validator dispatches command to Actuator (with token)
5. Actuator verifies token against Controller's public key
6. Actuator executes (if valid) or rejects (if invalid)

## Cognitive Profiles (AI Integration Point)

Stored in `priv/profiles/*.yaml`, these define agent personalities:

```yaml
meta:
  name: "controller_judge"
  role: "Policy Compliance Officer"

system_prompt: |
  You are the Policy Judge...
  
allowed_tools:
  - "submit_policy_verdict"

routing_rules:
  on_success: "transition_to_security"
```

**Why YAML?** Hot-swappable. Edit prompts without recompiling. Deploy personality updates at runtime.

## Genesis Protocol

Launch the universe:

```bash
mix run scripts/genesis.exs
```

Watch a single command bootstrap an autonomous hierarchy:
1. Root node self-initializes
2. Determines identity (Leaf/Manager)
3. Loads cognitive profiles
4. Executes workflow
5. Spawns children (if Manager)
6. Children repeat 1-5 recursively

## Observable Telemetry

LiveWire emits `:telemetry` events for external observability:
- Task completions
- Validation failures (pain signals)
- Stress accumulation
- Critical thresholds

Integrate with Phoenix LiveView, StatsD, or any telemetry consumer to watch the organism's heartbeat in real-time.

## What Makes This Different?

**AutoGPT/LangChain**: Single-agent, external orchestration, no self-validation  
**ACN**: Multi-agent swarm, self-orchestrating, self-validating, fault-tolerant

**Microsoft Semantic Kernel**: Library/framework, requires human integration  
**ACN**: Self-contained organism, operates autonomously

**OpenAI Assistants API**: Closed ecosystem, vendor lock-in  
**ACN**: Open architecture, BEAM native, distributed by design

**Existing Elixir Agents**: Stateless wrappers around LLM APIs  
**ACN**: Stateful OTP processes with supervision, identity, memory, stress tracking

## Current Limitations

- **Mock Logic**: Cognitive decisions currently stubbed (LLM integration is next phase)
- **Single-VM**: Uses local DynamicSupervisor instead of distributed Erlang clustering
- **No Persistent Memory**: External memory client (ACMS) not implemented
- **Manual Genesis**: Still requires human to run `genesis.exs`

## The Vision

Imagine:
- Deploy one root node to a Kubernetes cluster
- It reads your architecture doc and epic list
- It spawns manager nodes for each epic
- Managers spawn worker nodes for each story
- Workers write code, tests, docs
- Validators run tests, report to managers
- Managers aggregate results, report to root
- Root synthesizes release notes, triggers CI/CD
- **You wake up to a merged PR**

That's the north star. This codebase is the foundation.

## Quick Start

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run genesis
mix run scripts/genesis.exs

# Watch the logs. That's your organism thinking.
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│                  SupervisorAgent                     │
│         (Genesis, Identity, Child Spawning)          │
└────────────────────┬────────────────────────────────┘
                     │ handoff
                     ↓
┌─────────────────────────────────────────────────────┐
│                   Controller                         │
│  (Legislator → Architect → Judge → Security Officer) │
└──┬──────────┬──────────┬──────────┬─────────────────┘
   │          │          │          │
   │ govern   │ delegate │ validate │ authorize
   ↓          ↓          ↓          ↓
┌──────┐  ┌──────────┐ ┌──────────┐ ┌────────┐
│ Task │  │Specialist│ │Validator │ │Actuator│
│ Mgr  │  │(Draft)   │ │(QA Loop) │ │(Exec)  │
└──────┘  └──────────┘ └──────────┘ └────────┘
   │          │            │            │
   └──────────┴────────────┴────────────┘
                     │
                     ↓
              ┌─────────────┐
              │ Synthesizer │
              │  (Archive)  │
              └─────────────┘
```

## License

MIT

## Contributing

This is experimental research code. If you want to contribute, the biggest impact areas:
1. **LLM Integration**: Replace mock logic in Controller/Specialist with real inference
2. **Distributed Clustering**: Convert NodeSupervisor from local to distributed Erlang
3. **ACMS Implementation**: Build the external memory server
4. **Phoenix Dashboard**: LiveView UI for visualizing the organism's neural activity

Open an issue first. Let's talk architecture before code.

---

**Built with Elixir, OTP, and a healthy disrespect for the phrase "AI can't write production code."**
