defmodule ACN.Agents.LiveWire do
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Router
  alias ACN.Observability.Emitter

  defmodule State do
    defstruct stress_level: 0.0, 
              decay_rate: 1.0, 
              history: [], 
              router: %Router.State{},
              strike_count: 0,
              cpu_load: 0.0,
              node_id: nil
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    node_id = opts[:node_id] || "root"
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  def pain_signal(amount) do
    GenServer.cast(via_tuple(), {:pain_signal, amount})
  end

  def get_stress_level do
    try do
      GenServer.call(via_tuple(), :get_stress)
    catch
      :exit, _ -> 0.0 # Fail-open: No throttling if unreachable
    end
  end

  @doc """
  Public API for remote polling. Returns {:ok, node, stress, memory}.
  """
  def get_remote_metrics do
    stress = get_stress_level()
    mem = :erlang.memory(:total)
    {:ok, node(), stress, mem}
  end

  @doc """
  Returns the recommended throttle delay in milliseconds based on current stress.
  """
  def get_throttle_delay do
    stress = get_stress_level()
    calculate_throttle(stress)
  end

  @doc """
  Blocks the caller if the system is stressed.
  """
  def wait_for_homeostasis do
    delay = get_throttle_delay()
    if delay > 0 do
      if delay == :infinity do
        Logger.warning("LiveWire: System Freeze initiated due to 100% stress.")
        Process.sleep(:infinity) # Freeze
      else
        Logger.info("LiveWire: Throttling system for #{delay}ms (Stress: High)")
        Process.sleep(delay)
      end
    else
        Logger.debug("LiveWire: No throttling (Stress nominal).")
    end
    :ok
  end

  defp via_tuple(node_id \\ "root") do
    NodeRegistry.via_tuple(:live_wire, "#{node_id}_live_wire")
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    node_id = opts[:node_id] || "root"
    # Schedule Decay Tick (1000ms)
    :timer.send_interval(1000, :decay_tick)

    # Initialize Router (Will be enriched in after_init)
    router_state = %Router.State{
      agent_role: :live_wire,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    send(self(), :after_init)

    {:ok, %State{router: router_state, node_id: node_id}}
  end

  @impl true
  def handle_info(:after_init, state) do
    node_id = state.node_id
    {:noreply, %{state | node_id: node_id}}
  end

  @impl true
  def handle_info(:decay_tick, state) do
    new_stress = max(0.0, state.stress_level - state.decay_rate)
    {:noreply, %{state | stress_level: new_stress}}
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
  def handle_cast({:pain_signal, amount}, state) do
    new_stress = min(100.0, state.stress_level + amount)

    state = check_thresholds(state, state.stress_level, new_stress)

    # HSG: Push autonomic vector — non-blocking, zero-contention
    Emitter.push_autonomic(new_stress, state.strike_count)
    Emitter.flush_and_broadcast(:monitoring, :stress_tick, state.node_id)

    {:noreply, %{state | stress_level: new_stress}}
  end

  @impl true
  def handle_cast({:livewire_alert, payload}, state) do
    Logger.error("""
    ==================================================================
    ⚡ LIVE WIRE TRIGGERED ⚡
    
    ISSUE: #{payload.issue}
    
    CONTEXT:
    - Path: #{payload.path}
    - Task: #{payload.task}
    - Supervisor: #{inspect(payload.supervisor_pid)}
    
    ACTION: SYSTEM FREEZE INITIATED. WAITING FOR HUMAN INTERVENTION.
    ==================================================================
    """)
    
    # Escalate Stress to Maximum
    new_stress = 100.0

    # HSG: Emit a critical autonomic event
    Emitter.push_autonomic(new_stress, state.strike_count)
    Emitter.flush_and_broadcast(:monitoring, :livewire_freeze, state.node_id)
    
    {:noreply, %{state | stress_level: new_stress}}
  end

  @impl true
  def handle_cast(:rescue, state) do
    Logger.info("LiveWire: RESCUE SIGNAL RECEIVED. Resetting stress levels and strikes.")
    {:noreply, %{state | stress_level: 0.0, strike_count: 0}}
  end

  @impl true
  def handle_cast({:fatal_error, reason}, state) do
    new_strikes = state.strike_count + 1
    Logger.error("LiveWire: FATAL ERROR RECEIVED. Strike #{new_strikes}: #{reason}")
    
    # Broadcast Trauma Alert if Strike 3
    if new_strikes >= 3 do
       Router.route({:pain_signal, "Strike 3: #{reason}"}, {:sideways, :pain_signal}, state.router)
    end
    
    {:noreply, %{state | strike_count: new_strikes}}
  end

  @impl true
  def handle_call(:get_stress, _from, state) do
    {:reply, state.stress_level, state}
  end

  # --- Helpers ---

  defp calculate_throttle(stress) do
    cond do
      stress < 50.0 -> 0
      stress < 80.0 ->
        # Linear 50-80 maps to 0-2000
        ratio = (stress - 50) / 30
        round(ratio * 2000)
      stress < 99.0 ->
        # Exponential 80-99 maps to 2000-10000
        # Simple curve fit or just rough steps
        2000 + round(:math.pow((stress - 80), 2) * 20) # Rough mapping
      stress >= 99.0 -> :infinity
    end
  end

  defp check_thresholds(state, old_val, new_val) do
    cond do
      old_val < 50.0 and new_val >= 50.0 -> broadcast_alert(state, :warning)
      old_val < 80.0 and new_val >= 80.0 -> broadcast_alert(state, :critical)
      old_val < 95.0 and new_val >= 95.0 -> broadcast_alert(state, :panic)
      true -> state
    end
  end

  defp broadcast_alert(state, level) do
    Logger.warning("LiveWire Alert: System Stress reached #{level} level.")
    # Broadcast to Trauma Line if panic
    if level == :panic or level == :critical do
       Router.route({:pain_signal, "Stress Level: #{level}"}, {:sideways, :pain_signal}, state.router)
    end
    state
  end
end
