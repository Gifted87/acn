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
  config :acn, :ai,
    default_adapter: ACN.AI.Adapters.GeminiAdapter,
    local_llm: [
      repo_id: "driaforall/Tiny-Agent-a-1.5B"
    ],
    ollama: [
      base_url: System.get_env("OLLAMA_BASE_URL", "http://localhost:11434"),
      model: System.get_env("OLLAMA_MODEL", "qwen3:0.6b")
    ],
    openai: [
      api_key: System.get_env("DASHSCOPE_API_KEY"),
      base_url: System.get_env("OPENAI_BASE_URL", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
      model: System.get_env("OPENAI_MODEL", "qwen-flash"),
      # Safety: Hard timeout for the request itself (increased to match Ollama)
      request_timeout: 300_000,
      # Retry Configuration
      retry_max_attempts: 3,
      retry_base_delay: 1000
    ],
    gemini: [
      api_key: System.get_env("GEMINI_API_KEY"),
      model: System.get_env("GEMINI_MODEL", "gemini-2.5-flash-lite"),
      enable_thinking: true,
      # Safety: Hard timeout for the request itself
      request_timeout: 300_000,
      # Retry Configuration
      retry_max_attempts: 3,
      retry_base_delay: 1000
    ]

  config :mnesia,
    dir: to_charlist(System.get_env("MNESIA_DIR") || "priv/data/mnesia_#{node()}")

  config :acn, :cluster,
    seed_nodes: System.get_env("SEED_NODES", "") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
  # Memory Configuration (ACMS Backend)
  config :acn, :memory,
    cms_url: System.get_env("CMS_URL", "http://localhost:4000"),
    cms_api_key: System.get_env("CMS_API_KEY")

  # AI Compilation Target
  config :nx, :default_backend, EXLA.Backend
end
