import Config

# Configures Elixir's Logger
config :logger,
  backends: [:console, {LoggerFileBackend, :file_log}, {LoggerFileBackend, :audit_log}, {LoggerFileBackend, :error_log}]

# 1. Console: Warnings/Errors Only (Clean screen)
config :logger, :console,
  format: "$time [$level] $message\n",
  metadata: [:pid],
  level: :warning

# 2. Debug File: Detailed operational logs
config :logger, :file_log,
  path: "logs/acn_debug.log",
  level: :debug,
  format: "$date $time [$level] $metadata$message\n",
  metadata: [:pid, :module, :function]

# 3. Audit File: Structured tracing (ACN.Observability.AuditLogger)
config :logger, :audit_log,
  path: "logs/acn_audit.log",
  level: :info,
  format: "$message\n", # Raw message format for structured JSON lines
  metadata: []

# 4. Error File: Only errors (printed in red in console)
config :logger, :error_log,
  path: "logs/acn_error.log",
  level: :error,
  format: "$time [$level] $message\n",
  metadata: [:pid, :module, :function]

# Use Jason for JSON encoding
# Use Jason for JSON encoding (Standard)
# config :phoenix, :json_library, Jason

# Workspace Root (Safe container for file operations)
config :acn, :workspace_root, "tmp/acn_workspaces"

# Phoenix Endpoint Configuration
config :acn, ACNWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 5051],
  server: true,
  secret_key_base: System.get_env("SECRET_KEY_BASE") || "VGhpcyBpcyBhIHNlY3JldCBrZXkgYmFzZSBmYWxsYmFjayBmb3IgZGV2",
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT") || "acn_live_salt_fallback"],
  pubsub_server: ACN.PubSub,
  render_errors: [view: ACNWeb.ErrorView, accepts: ~w(html json), layout: false]

# Phoenix PubSub
config :acn, ACN.PubSub, []

# Use Jason for JSON
config :phoenix, :json_library, Jason

config :acn, :clean_start, true
config :acn, :enable_local_serving, false
config :acn, :enable_embeddings, false

# AI Backend Configuration
config :nx, :default_backend, EXLA.Backend
config :nx, :default_defn_options, [compiler: EXLA, client: :host]

import_config "#{config_env()}.exs"

# HSG Observability Configuration
config :acn, :hsg,
  shadow_root: "tmp/acn_workspaces",
  max_shadow_file_bytes: 50 * 1024 * 1024,  # 50MB
  chain_verify_on_boot: false,
  panopticon_snapshot_interval_ms: 100
