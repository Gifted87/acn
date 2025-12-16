import Config

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :pid]

# Use Jason for JSON encoding
# Use Jason for JSON encoding (Standard)
# config :phoenix, :json_library, Jason

# Workspace Root (Safe container for file operations)
config :acn, :workspace_root, "tmp/acn_workspaces"

# Phoenix Endpoint Configuration
config :acn, ACNWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: "VGhpcyBpcyBhIHNlY3JldCBrZXkgYmFzZSBmb3IgZGV2ZWxvcG1lbnQgb25seQ==",
  live_view: [signing_salt: "acn_live_salt"],
  pubsub_server: ACN.PubSub,
  render_errors: [view: ACNWeb.ErrorView, accepts: ~w(html json), layout: false]

# Phoenix PubSub
config :acn, ACN.PubSub, []

# Use Jason for JSON
config :phoenix, :json_library, Jason

config :acn, :clean_start, true
config :acn, :enable_local_serving, false

# AI Backend Configuration
config :nx, :default_backend, EXLA.Backend
config :nx, :default_defn_options, [compiler: EXLA, client: :host]

import_config "#{config_env()}.exs"
