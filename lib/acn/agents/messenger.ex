defmodule ACN.Agents.Messenger do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry

  defmodule State do
    defstruct log_buffer: [], batch_size: 10, last_flush: nil, node_id: "root"
  end

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:messenger, :messenger)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    # Subscribe to internal raw events
    Phoenix.PubSub.subscribe(ACN.PubSub, "internal:raw_events")

    # Schedule periodic flush (every 2 seconds)
    :timer.send_interval(2000, :flush_check)

    {:ok, %State{last_flush: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info({:event, event}, state) do
    # Append to buffer
    new_buffer = [event | state.log_buffer]

    # Check if we should flush
    should_flush = length(new_buffer) >= state.batch_size

    if should_flush do
      flush_and_summarize(new_buffer, state)
      {:noreply, %{state | log_buffer: [], last_flush: System.monotonic_time(:second)}}
    else
      {:noreply, %{state | log_buffer: new_buffer}}
    end
  end

  @impl true
  def handle_info(:flush_check, state) do
    now = System.monotonic_time(:second)
    time_since_flush = now - state.last_flush

    # Flush if buffer not empty and 2+ seconds passed
    if length(state.log_buffer) > 0 and time_since_flush >= 2 do
      flush_and_summarize(state.log_buffer, state)
      {:noreply, %{state | log_buffer: [], last_flush: now}}
    else
      {:noreply, state}
    end
  end

  # --- Helpers ---

  defp flush_and_summarize(events, state) do
    # Spawn async task to avoid blocking GenServer
    Task.start(fn ->
      summarize_and_broadcast(events, state.node_id)
    end)
  end

  defp summarize_and_broadcast(events, node_id) do
    # Load Chronicler Profile
    vars = %{events: Enum.reverse(events)} # Reverse to chronological order

    case ACN.Core.ProfileLoader.load("messenger_chronicler", vars) do
      {:ok, profile} ->
        buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
        config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}

        summary =
          case ACN.AI.Pipeline.run(buffer, [], config) do
            {:ok, msg, _} -> msg.content |> String.trim()
            _ -> "System Active (#{length(events)} events)"
          end

        # Broadcast to Dashboard
        Phoenix.PubSub.broadcast(ACN.PubSub, "acn:node:#{node_id}", {:status_update, summary})
        Logger.info("Chronicler: #{summary}")

      {:error, reason} ->
        Logger.error("Failed to load Chronicler profile: #{inspect(reason)}")
    end
  end
end
