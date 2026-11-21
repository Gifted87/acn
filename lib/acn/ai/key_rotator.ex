defmodule ACN.AI.KeyRotator do
  @moduledoc """
  GenServer that rotates through a list of API keys in a round-robin fashion.
  Reads keys from `GEMINI_API_KEYS` (comma-separated) or falls back to `GEMINI_API_KEY`.
  """
  use GenServer
  require Logger

  @name __MODULE__

  # --- API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  @doc """
  Returns the next key in the rotation.
  """
  def get_key do
    GenServer.call(@name, :get_key)
  end

  # --- Callbacks ---

  @impl true
  def init(_) do
    keys = load_keys()
    
    if keys == [] do
      Logger.warning("[KeyRotator] No API keys found in GEMINI_API_KEYS or GEMINI_API_KEY environment variables.")
    else
      Logger.info("[KeyRotator] Initialized with #{length(keys)} keys.")
    end

    {:ok, %{keys: keys, index: 0}}
  end

  @impl true
  def handle_call(:get_key, _from, %{keys: []} = state) do
    {:reply, nil, state}
  end

  def handle_call(:get_key, _from, %{keys: keys, index: index} = state) do
    key = Enum.at(keys, index)
    new_index = rem(index + 1, length(keys))
    {:reply, key, %{state | index: new_index}}
  end

  # --- Helpers ---

  defp load_keys do
    keys_str = System.get_env("GEMINI_API_KEYS")
    
    cond do
      keys_str != nil && String.trim(keys_str) != "" ->
        keys_str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      (default_key = System.get_env("GEMINI_API_KEY")) != nil && String.trim(default_key) != "" ->
        [default_key]

      true ->
        []
    end
  end
end
