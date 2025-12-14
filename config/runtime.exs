import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below is only executed in release mode.

if System.get_env("PHX_SERVER") do
  # (If we had Phoenix, config would go here)
end

# Hardware Adapter
config :acn, :hardware_adapter,
  if(System.get_env("NERVES_ENV"), do: ACN.Actuator.Hardware.CircuitsGPIO, else: ACN.Actuator.Hardware.Simulated)

# CONFIG MANDATE: Fail Fast if Keys are Missing
if config_env() != :test do
  openai_key = System.fetch_env!("OPENAI_API_KEY")

  config :acn, :ai,
    default_adapter: ACN.AI.Adapters.OpenAI,
    openai: [
      api_key: openai_key,
      base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
      model: System.get_env("OPENAI_MODEL", "gpt-4-turbo-preview"),
      # Safety: Hard timeout for the request itself
      request_timeout: 60_000,
      # Retry Configuration
      retry_max_attempts: 3,
      retry_base_delay: 1000
    ]

  config :mnesia,
    dir: to_charlist(System.get_env("MNESIA_DIR") || "priv/data/mnesia_#{node()}")

  config :acn, :cluster,
    seed_nodes: System.get_env("SEED_NODES", "") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
  config :acn, :memory,
    qdrant_url: System.get_env("QDRANT_URL", "http://localhost:6333"),
    qdrant_key: System.get_env("QDRANT_API_KEY")

  # AI Compilation Target
  config :nx, :default_backend, EXLA.Backend
end
