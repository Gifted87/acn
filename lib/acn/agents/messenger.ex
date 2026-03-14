defmodule ACN.Agents.Messenger do
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Router

  defmodule State do
    defstruct log_buffer: [], batch_size: 10, last_flush: nil, node_id: "root", router: %Router.State{}
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    node_id = opts[:node_id] || "root"
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  defp via_tuple(node_id) do
    NodeRegistry.via_tuple(:messenger, "#{node_id}_messenger")
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    node_id = opts[:node_id] || "root"
    # Schedule periodic flush (every 2 seconds)
    :timer.send_interval(2000, :flush_check)

    # Initialize Router
    router_state = %Router.State{
      agent_role: :messenger,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    send(self(), :after_init)

    {:ok, %State{router: router_state, node_id: node_id}}
  end

  @impl true
  def handle_cast({:set_local_identity, _identity}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:routed_message, _sender, payload}, state) do
    GenServer.cast(self(), payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:after_init, state) do
    # Fetch Node ID for topic wiring
    node_id = state.node_id
    
    # 1. Subscribe to internal raw events (Agent Sideways Wiring)
    Phoenix.PubSub.subscribe(ACN.PubSub, "acn:node_internal:#{node_id}")
    
    # 2. Subscribe to Control Topic (Command Line)
    Phoenix.PubSub.subscribe(ACN.PubSub, "acn:control:#{node_id}")

    {:noreply, %{state | node_id: node_id, last_flush: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info({:routed_sideways, role, payload}, state) do
    # Treat as an event for Chronicler and AuditBuffer
    event = %{agent: role, payload: payload, timestamp: DateTime.utc_now()}
    handle_info({:event, event}, state)
  end

  @impl true
  def handle_info({:event, event}, state) do
    # Forward to AuditBuffer for per-node siloed logs
    ACN.Core.AuditBuffer.log(state.node_id, inspect(event))

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
  def handle_info({:command, "PAUSE"}, state) do
    Logger.warning("Messenger: PAUSE Command Received via Control Topic. Verifying and Routing...")
    # Verify and Route to Local Supervisor
    Router.route({:override, :pause}, {:local, :supervisor}, state.router)
    {:noreply, state}
  end

  @impl true
  def handle_info({:command, "RESTART"}, state) do
    Logger.warning("Messenger: RESTART Command Received via Control Topic. Routing to Supervisor...")
    Router.route({:override, :restart}, {:local, :supervisor}, state.router)
    {:noreply, state}
  end

  def handle_info({:command, "CONTINUE"}, state) do
    Logger.warning("Messenger: CONTINUE Command Received via Control Topic. Routing to Controller...")
    Router.route({:continue}, {:local, :controller}, state.router)
    {:noreply, state}
  end

  @impl true
  def handle_info({:command, cmd}, state) do
    Logger.info("Messenger: Received unknown command: #{cmd}")
    {:noreply, state}
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
    # 0. Fetch Deep Context from Supervisor
    target_id = node_id # Supervisor ID is the node_id
    deep_ctx = 
      case GenServer.call(NodeRegistry.via_tuple(:supervisor, target_id), :get_context, 1000) do
        {:ok, ctx} -> ctx
        _ -> nil
      end

    # Load Chronicler Profile
    vars = %{
      events: Enum.reverse(events), 
      deep_context: deep_ctx
    }

    case ACN.Core.ProfileLoader.load("messenger_chronicler", vars) do
      {:ok, profile} ->
        buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
        config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}

        summary =
          case ACN.AI.Pipeline.run(buffer, ["submit_chronicle"], config) do
            {:ok, msg, _, _} -> msg.content |> String.trim()
            _ -> "System Active (#{length(events)} events)"
          end

        # Broadcast to Dashboard (The Narrative Line)
        Phoenix.PubSub.broadcast(ACN.PubSub, "acn:dashboard:#{node_id}", {:narrative_update, summary})
        
        # Write to Chronicle File on disk
        if deep_ctx && deep_ctx.path do
          write_chronicle(deep_ctx.path, summary)
        end
        
        Logger.info("Chronicler: #{summary}")

      {:error, reason} ->
        Logger.error("Failed to load Chronicler profile: #{inspect(reason)}")
    end
  end

  defp write_chronicle(path, summary) do
    chronicle_path = Path.join(path, "_chronicle.md")
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    entry = "### [#{timestamp}]\n#{summary}\n\n"
    
    File.write!(chronicle_path, entry, [:append])
  rescue
    e -> Logger.error("Messenger: Failed to write chronicle for #{path}: #{inspect(e)}")
  end
end
