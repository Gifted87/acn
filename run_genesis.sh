#!/bin/bash

# ProCoder Genesis Script
# This command ignites the ProCoder autonomous coding harness.

MIX_ENV=dev mix acn.genesis --task "ProCoder is a fault-tolerant, autonomous AI coding harness built natively on Elixir and the BEAM Virtual Machine. Its fundamental purpose is to transcend the brittle, single-threaded amnesia of standard Python-based agents by establishing a highly concurrent, stateful, and cognitively persistent synthetic software engineer capable of long-horizon, complex execution.

Operating as a distributed localhost system, ProCoder’s architecture is anchored by a robust OTP Supervision Tree. The reasoning core abandons standard while loops for a Finite State Machine (gen_statem), transitioning asynchronously across idle, planning, thinking, tool execution, and verifying states. Because state is immutable, the /rewind command utilizes a history stack to instantly revert both LLM memory and filesystem Git stashes. The SessionManager leverages this process isolation to unlock massive parallelization via the /swarm command, spawning distinct agent processes in isolated Git worktrees to execute simultaneous, non-blocking execution.

Key sub-components include:
1. Brain: LLM connection pool (Finch), PromptEngine (salience ranking), and RateLimiter.
2. Memory: ETS for hot caching and Compactor for log synthesis.
3. Tooling: Language Server management and ToolRegistry.
4. ControlPlane: CommandRouter, TUI for visual diffs, and UX Policy Engine.
5. CodeGraph: AST parsing (Rustler/Tree-sitter) into SQLite-vec for Graph-RAG.
6. Planner: Goal decomposition via libgraph with recovery subgraphs.
7. Search: Gradient of Precision cascade (LSP -> ripgrep -> sqlite-vec).
8. Actuator: Erlang Ports for sandboxed asynchronous I/O (Bubblewrap/Seatbelt).
9. SDK: Macro DSL for rapid custom agent construction."
