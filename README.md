# Autonomous Cognitive Network (ACN)

ACN is an experimental Elixir/OTP application for coordinating AI-assisted software tasks through supervised processes. It includes task planning and execution components, model adapters, workspace tools, and a Phoenix-based activity dashboard.

The project is under active development. Treat it as a research prototype; its current development configuration is not suitable for untrusted or production workloads.

## Features

- Elixir/OTP supervision for the application and agent processes
- Mix tasks for starting a task (`acn.genesis`) and sending a recovery signal (`acn.rescue`)
- Adapters for OpenAI-compatible APIs, Google Gemini, and Ollama
- Workspace and judicial tools for reading, writing, and reviewing project files
- Optional connection to the ACMS service for memory operations
- Phoenix dashboard and telemetry over the local web endpoint

## Requirements

- Elixir 1.14 or later
- Erlang/OTP 25 or later
- Rust and Cargo for native components built with Rustler
- An LLM provider if you want to run model-backed tasks
- ACMS is optional and only needed for memory-service features

## Setup

```bash
git clone https://github.com/Gifted87/acn.git
cd acn
mix deps.get
cp .env.example .env
```

Edit `.env` with the settings you need. Set unique `SECRET_KEY_BASE` and `LIVE_VIEW_SALT` values for your local instance; never reuse credentials or commit `.env`. The checked-in template contains example values and must not be used as production secrets.

Common settings include:

| Variable | Purpose |
| --- | --- |
| `OPENAI_API_KEY` or `OPENAI_API_KEY_FILE` | Credentials for the configured OpenAI-compatible endpoint |
| `OPENAI_BASE_URL` | OpenAI-compatible API base URL |
| `OPENAI_MODEL` | Model name for that endpoint |
| `GEMINI_API_KEY` | Optional Gemini credential |
| `OLLAMA_BASE_URL` and `OLLAMA_MODEL` | Optional local Ollama endpoint and model |
| `CMS_URL` and `CMS_API_KEY` | Optional ACMS service connection |
| `MNESIA_DIR` | Optional location for local Mnesia state |

Compile the project:

```bash
mix compile
```

## Run

Start a task with a prompt:

```bash
mix acn.genesis --task "Describe the software task to perform"
```

The application reports dashboard information when it starts. The Phoenix endpoint currently listens on port `5051` and binds to all interfaces. It has no access-control layer, so keep it on a trusted, isolated development machine and do not expose it to the public internet.

To check the optional ACMS connection:

```bash
mix acn.init_memory
```

To send a recovery signal to the root node:

```bash
mix acn.rescue
```

Install the optional judicial browser runtime with:

```bash
./scripts/setup_judicial_browser.sh
```

## Development and security notes

- Development configuration enables simulation mode, where command execution may run directly on the host. Use an isolated workspace and inspect the task prompt before running it.
- ACN telemetry and shadow artifacts can include prompts, file changes, and workspace paths. Do not feed the system confidential material unless your logging and retention practices allow it.
- Local Mnesia databases, logs, generated artifacts, and `.env` files are runtime data. Keep them out of source control and replace any tracked runtime data with clean sample data before publishing.
- The current dashboard and development settings are prototypes, not a security boundary. Review the execution sandbox, network binding, and secret configuration before deployment.

## Repository layout

- `lib/acn/agents/` — agent and orchestration processes
- `lib/acn/ai/` — model adapters and AI support code
- `lib/acn/tools/` — workspace, planning, governance, and judicial tools
- `lib/acn/observability/` — telemetry and dashboard data
- `lib/acn_web/` — Phoenix endpoint and web interface
- `priv/profiles/` — role and agent profile configuration
- `native/` — Rustler components

## License

No license file is currently included. All rights remain with the respective copyright holder unless a license is added.
