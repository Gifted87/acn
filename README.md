# Autonomous Cognitive Network (ACN)

## 1. The Meaning of the System: What is the ACN?

To understand the **Autonomous Cognitive Network (ACN)**, one must first deconstruct its name, as it perfectly encapsulates the system’s fundamental architecture and ultimate objective:

*   **Autonomous**: The system does not require a human-in-the-loop to hold its hand through every file creation, bug fix, or architectural decision. Once given a "Prime Directive" (the initial human prompt), the system governs itself. It plans, writes, validates, self-corrects, and merges code entirely on its own.
*   **Cognitive**: The system does not treat code as mere text strings. It possesses "Consciousness" through its integration with semantic memory (ACMS) and its rigid Deep Context pillars. It reasons about dependencies, architectural intent, and security implications before it writes a single line of code.
*   **Network (The Lattice)**: This is the most critical distinction. The ACN is not a single, monolithic "chatbot" script. It is a highly concurrent, distributed *lattice* of interconnected, specialized AI agents running on the Erlang/BEAM Virtual Machine. It models a digital ecosystem of neuro-inspired nodes that communicate horizontally (sideways) and vertically (upstream/downstream) to orchestrate massive engineering efforts.

### The Ultimate Goal
The purpose of the ACN is to autonomously synthesize complex, security-hardened backend systems from scratch. 

Modern Large Language Models (LLMs) suffer from severe limitations: context exhaustion, "lazy programming" (e.g., leaving `// TODO: Implement later` stubs), and an inability to maintain architectural cohesion across dozens of files. ACN was built to shatter these limitations. 

ACN achieves production readiness not through a simple prompting mandate, but through its fundamental architecture. By utilizing continuous, recursive, and hierarchical task decomposition, the ACN continuously breaks down massive goals through layers of intermediate nodes until a task becomes so atomic and simple that a single node can implement it concretely without hallucinating. Supported by deep context propagation, this ensures agents write 100% complete, battle-tested, concrete logic. If an ACN agent attempts to use a placeholder or fake a cryptographic signature, the internal ACN Judge instantly disqualifies the work and triggers a strict remediation cycle. The network does not stop until a fully functioning, dependency-compliant, security-hardened system is materialized on disk.

---

## 2. The Solution to Complexity: Continuous Recursive Decomposition

The fatal flaw of attempting to build a complex software system with a standard AI agent is the assumption that a single prompt and a single context window can hold an entire architecture. They cannot. The ACN solves this through **Continuous Recursive Decomposition**.

This continuous and recursive hierarchical task decomposition is the core architectural engine that enables true -level production readiness. Instead of trying to build a 50-file backend in one pass, the ACN operates as a **Fractal Hierarchy**. It conquers complexity by dividing it continuously with more and more intermediate nodes until the task becomes so atomic and simple that a single node can implement it concretely without hallucinating.

1.  **The Root Node (The Chief Architect)**: The Genesis command ignites the Root Node with the human's "Prime Directive" (e.g., "Build a scalable, distributed chat backend with JWT auth and Postgres"). The Root Node does not write code. It acts as the Chief Architect, defining the global blueprint and decomposing the prompt into top-level domains (e.g., Auth Subsystem, Database Subsystem, WebSocket Subsystem).
2.  **Intermediate Nodes (The Middle Managers)**: The Root spawns Intermediate Nodes for each domain. These nodes receive their scoped task and further decompose it. They use the `TaskManager` to generate a Directed Acyclic Graph (DAG) of parallel sub-tasks. They organize these tasks into strict sequential batches (e.g., Batch 1: Database Schemas. Batch 2: Business Logic. Batch 3: API Controllers) to ensure dependencies are resolved chronologically.
3.  **Leaf Nodes (The Workers)**: The Intermediate nodes spawn Leaf Nodes. These are atomic execution units. A Leaf Node is strictly confined to modifying a single file or a highly cohesive, microscopic set of files. Because the task has been recursively decomposed, the Leaf Node's LLM only has to focus on writing *one perfect file*.

By recursively breaking down the goal, the ACN ensures that the LLM is never overwhelmed. It applies its full cognitive power to atomic, manageable chunks, which are then rolled back up the hierarchy via an **Upstream Merge** to form the final, complex system.

---

## 3. Epistemological Integrity: Deep Context Propagation

When tasks are recursively decomposed, how does a Leaf Node at depth 4 remember the original architectural vision of the Root Node? How does the system prevent the "Telephone Game" where requirements degrade as they are passed down?

ACN solves this via **Deep Context Propagation**. This architecture guarantees that the deep context provides all the context a single node operating on any part of the project needs to execute its task. Every single node in the lattice is hydrated with a rigid data structure known as the **Seven Pillars of Deep Context**:

1.  **Pillar I: The Blueprint (The "Why" and "How")**: The technical narrative generated by the parent node. It tells the child exactly how its specific task fits into the immediate parent's architecture.
2.  **Pillar II: The Rules (The "Must" and "Must Not")**: A strict inheritance of laws. This includes *Master Rules* (immutable system laws, like "No destructive filesystem ops"), *Ancestral Rules* (inherited from grandparents), and *Local Rules* (specific to the current task).
3.  **Pillar III: The Worksheet (The "What Is")**: An inventory of reality. It lists all artifacts, files, and plans already created and verified by sibling and parent nodes. This prevents the LLM from hallucinating duplicates or reinventing existing modules.
4.  **Pillar IV: The ACMS (The "What We Know")**: Just-In-Time semantic search results injected directly into the prompt. This provides the node with historical wisdom and code snippets retrieved from the associative memory grid.
5.  **Pillar V: The Task (The "Job")**: The atomic, specific instruction this node must execute.
6.  **Pillar VI: The Path (The "Where")**: The absolute, strictly jailed directory path where the node is permitted to operate.
7.  **Pillar VII: The Original Specification (The "Prime Directive")**: This is the ultimate safeguard. The immutable, original human prompt is passed down to every generation (up to a safe depth limit). This ensures that every Leaf Node acts with 1:1 fidelity to the creator's original vision, completely eliminating architectural drift.

---

## 4. Structural Organization: The Node Enclave

In the ACN, a "Node" is not a single script. It is an **Enclave**—an isolated Erlang supervision tree (`EnclaveSupervisor`) containing a specialized suite of heavily concurrent, communicating agents. This structural organization mimics a human engineering team:

*   **SupervisorAgent**: The lifecycle manager. It handles context hydration, lineage tracing (who is my parent/grandparent?), and determines if the enclave should act as an Intermediate (Planner) or Leaf (Worker).
*   **Controller (The Brain)**: Manages the state machine. It handles **Legislation** (synthesizing local rules and blueprints), **Architecting** (delegating work), and acts as the **Judge** (validating the final code written by the Actuator against the rules and blueprint).
*   **TaskManager**: Present in Intermediate nodes. It utilizes the `tm_planner` AI profile to logically map out the DAG of child tasks.
*   **Actuator (The Hands)**: Executes physical tools. It contains the `specialist_drafter` AI to write production-grade code, and the `actuator_remediator` AI to fix code if the Judge rejects it. It executes secure shell commands and filesystem mutations.
*   **Messenger (The Chronicler)**: Batches events and uses AI to generate human-readable narrative summaries of the node's progress, broadcasting them to the Panopticon dashboard.
*   **LiveWire (The Nervous System)**: Monitors the metabolic health of the enclave. It tracks CPU load, failure loops, and rejection counts. If stress hits 100%, it triggers a "System Freeze" or an automatic process respawn to prevent runaway API costs.

---

## 5. The Macro/Micro Symbiosis: ACN & ProCoder

It is vital to understand where ACN fits into the software engineering lifecycle. **ACN is the Macro-Architect.** 

ACN's job is bootstrapping. It generates the complex structural boilerplate, establishes the database schemas, wires the message brokers, enforces initial security constraints, and lays down the foundational codebase of a massive system from scratch.

However, ACN does not maintain the system indefinitely. Once ACN completes the macro-architecture, **it hands the codebase over to ProCoder**.

**ProCoder** (The Magnum Opus of Autonomous Software Synthesis) is the micro-architect and refiner. ProCoder uses its advanced *CodeGraph Engine*, AST-level forensics, and Vector-Symbolic Hybrid Search to surgically refine, optimize, bug-fix, and evolve the code that ACN generated. 
*   **ACN builds the city from the ground up.**
*   **ProCoder lives in the city, maintains the infrastructure, and evolves it.**

Together, ACN and ProCoder form a complete, end-to-end, AGI-level software lifecycle.

---

## 6. The Associative Cognitive Memory System (ACMS)

To prevent the catastrophic forgetting that plagues standard LLM agents over long horizons, ACN is deeply integrated with the **Associative Cognitive Memory System (ACMS)**.

ACMS is not a passive vector database; it is an **active, sovereign long-term brain**. Built on a network of Atomic Units of Cognition (Nodes), it operates on a physical-analogue process known as **Spreading Activation**.
*   **Discovery-Based Search**: When ACN queries the ACMS for "Database Authentication," the ACMS does not just return exact text matches. Through weighted synaptic links formed during previous operational cycles, it "activates" related concepts like "Token Expiration," "Connection Pooling," and "Security Middleware."
*   **Metabolic State**: Facts in the ACMS have energy states. Frequently used code patterns become "hot" and are retrieved instantly, while outdated legacy code "hibernates."
*   **Digital Birth Certificates (DBCs)**: When an ACN Leaf Node successfully finishes a file, it generates a DBC containing the source code, provenance, and cryptographic hashes. The ACN uses the `ingest_fact` tool to permanently immortalize this knowledge into the ACMS, ensuring the network becomes exponentially smarter with every project it completes.

---

## 7. Security Hardened: Sovereign Seals & Workspace Jailing

Autonomous systems capable of executing shell commands and writing files pose massive security risks. The ACN is engineered with a **Zero-Trust Security Lattice**.

*   **Ephemeral Cryptography (Sovereign Seals)**: Upon boot, every Node Enclave generates its own RSA Keypair (`TokenAuthority`). 
*   **Strict JWT Authorization**: The `Actuator` (the hands) cannot touch the disk on its own. The `Controller` (the brain) must mint a JSON Web Token (JWT) strictly scoped to a specific action and resource (e.g., `scope: fs_write, resource: /src/auth/login.ex`). The Actuator cryptographically verifies this token before executing the tool.
*   **Workspace Jailing (Spatial Containment)**: `ACN.Infrastructure.Workspace` ensures that all operations are jailed. If an agent attempts an operation like `write_to_file(path: "../../../etc/passwd")`, the `safe_path/3` function instantly blocks the spatial violation, emitting a severe trauma signal to the `LiveWire` nervous system, triggering an immediate security freeze.

---

## 8. Extreme Observability: The HSG Panopticon

Because ACN operates as a massively concurrent swarm of background processes, traditional `stdout` logging is useless. To solve this, ACN implements the **Hierarchical System Graph (HSG) Panopticon**.

Every single action taken by an agent is wrapped in a `MicroDBC` payload and broadcasted across **Five Vectors of Telemetry**:
1.  **Lattice (The Spine)**: Tracks Phase transitions and maintains a cryptographically hashed causal chain (`hash` and `prev_hash`).
2.  **Cognitive (The Brain)**: Records every LLM interaction, exact model parameters, token counts, and the raw prompts used.
3.  **Physical (The Hands)**: Logs every filesystem mutation with unified diffs and pre/post SHA-256 file checksums.
4.  **Security (The Immune System)**: Monitors all JWT minting events and access control (ACL) outcomes.
5.  **Autonomic (The Nervous System)**: Maps health metrics, CPU load, and rejection loops.

### The Spatial Introspection Layer (.shadow)
The ACN maintains a `.shadow` directory that mirrors the generated codebase. For every file ACN generates (e.g., `lib/router.ex`), the `ShadowWriter` generates a hidden metadata file (e.g., `.shadow/lib/router.ex/cognitive.jsonl`). This allows human engineers to do forensic "time travel," seeing exactly *what AI prompt* generated *what specific line of code*, and *why* the Judge approved it.

---

## 9. Standard Requirements & Installation

### Prerequisites
*   **Elixir** 1.14+ & **Erlang/OTP** 25+
*   **Rust & Cargo** (Required for compiling `Rustler` NIFs used in token counting and fast sandbox execution)
*   **PostgreSQL** (If integrating with the full ACMS memory grid)
*   **Supported LLMs**: Google Gemini (Native API), Ollama (Local), or OpenAI-compatible endpoints.

### Installation

1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/gifted87/acn.git
    cd acn
    ```

2.  **Install Dependencies**:
    ```bash
    mix deps.get
    ```

3.  **Configure Environment Variables**:
    ACN requires several environment variables for AI providers and system security.
    ```bash
    cp .env.example .env
    # Edit .env and add your keys
    source .env
    ```

    | Variable | Required | Description |
    | :--- | :--- | :--- |
    | `GEMINI_API_KEY` | Yes (for Gemini) | Your Google AI SDK key. |
    | `DASHSCOPE_API_KEY` | Yes (for Qwen) | Your Alibaba DashScope API key. |
    | `SECRET_KEY_BASE` | Yes | Phoenix secret (Generate with `mix phx.gen.secret`). |
    | `LIVE_VIEW_SALT` | Yes | LiveView salt (Generate with `mix phx.gen.secret 32`). |
    | `CMS_API_KEY` | Partially | API key for the ACMS backend. |
    | `OLLAMA_BASE_URL` | No | Base URL for local Ollama instance. |

4.  **Database & Memory Grid Setup**:
    Initialize the local Mnesia schema and test the ACMS connection:
    ```bash
    mix acn.init_memory
    ```

5.  **Compilation**:
    Compile the application (Rustler will automatically fetch the Rust toolchain to compile the NIF bridges).
    ```bash
    mix compile
    ```

---

## 10. Ignition: The Genesis Sequence (CLI Usage)

The Autonomous Cognitive Network is ignited via the Genesis Mix task. Because ACN maintains Deep Context, the more detailed your architectural requirements, the better the synthesis.

```bash
mix acn.genesis --task "Build a highly concurrent Elixir backend for a distributed chat application. It must use PostgreSQL for persistence, Phoenix PubSub for real-time message delivery, and enforce JWT-based authentication. Ensure all Ecto schemas are fully implemented, and DO NOT use placeholder stubs for the cryptographic hashing functions."
```

**The Genesis Lifecycle:**
1.  **The Big Bang**: The Root Node is spawned.
2.  **Legislation**: The Root's Controller creates the Macro-Blueprint and system-wide rules.
3.  **Decomposition**: The TaskManager recursively spawns Intermediate Nodes for domains (Auth, Database, Networking).
4.  **Execution**: Leaf Nodes are spawned to write the actual code.
5.  **Observation**: You can monitor the live, fractal synthesis by opening the Panopticon Dashboard at `http://localhost:5051/dashboard`.

### System Rescue
If an agent hits an infinite logic loop or gets blocked by a strict security policy, the `LiveWire` will freeze the node to protect your API budgets. You can manually unfreeze the system using the rescue command:
```bash
# Rescues the entire system by resetting global stress levels
mix acn.rescue

# Rescues a specific stalled node
mix acn.rescue --node auth_controller_node
```

---

## 11. Configuration & Tuning (`config.exs`)

ACN relies heavily on functional configuration to dictate the limits of its autonomy. Modify `config/runtime.exs` to tune the system to your hardware and budget.

```elixir
config :acn, :ai,
  default_adapter: ACN.AI.Adapters.GeminiAdapter,
  gemini: [
    api_key: System.get_env("GEMINI_API_KEY"),
    model: "gemini-3.1-flash-lite-preview",
    enable_thinking: true,
    request_timeout: 300_000,
    retry_max_attempts: 3
  ]

config :acn, :hsg,
  # The location of the spatial jailing directory
  shadow_root: "tmp/acn_workspaces"

config :acn, :cluster,
  # Migration threshold. If local CPU stress exceeds remote stress by 10%, 
  # the NodeSupervisor will RPC-spawn new agents on remote BEAM nodes.
  migration_threshold: 10.0
```

---

## 12. Conclusion & License

*Proprietary Infrastructure for **The Genesis Machine**. Developed by Gift Braimah.*

By utilizing continuous recursive decomposition, strict spatial jailing, deep context propagation, and an associative memory grid, the ACN bridges the gap between simple AI copilots and true Autonomous Software Engineering. It provides the resilient, neuro-inspired foundation required to synthesize the AGI-grade systems of tomorrow.

***

