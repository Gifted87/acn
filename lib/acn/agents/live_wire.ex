defmodule ACN.Agents.LiveWire do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry

  defmodule State do
    defstruct stress_level: 0.0, decay_rate: 1.0, history: []
  end

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
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

  defp via_tuple do
    NodeRegistry.via_tuple(:live_wire, :live_wire)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    # Schedule Decay Tick (1000ms)
    :timer.send_interval(1000, :decay_tick)
    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:pain_signal, amount}, state) do
    new_stress = min(100.0, state.stress_level + amount)

    check_thresholds(state.stress_level, new_stress)

    {:noreply, %{state | stress_level: new_stress}}
  end

  @impl true
  def handle_info(:decay_tick, state) do
    new_stress = max(0.0, state.stress_level - state.decay_rate)
    {:noreply, %{state | stress_level: new_stress}}
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

  defp check_thresholds(old_val, new_val) do
    cond do
      old_val < 50.0 and new_val >= 50.0 -> broadcast_alert(:warning)
      old_val < 80.0 and new_val >= 80.0 -> broadcast_alert(:critical)
      old_val < 95.0 and new_val >= 95.0 -> broadcast_alert(:panic)
      true -> :ok
    end
  end

  defp broadcast_alert(level) do
    Logger.warning("LiveWire Alert: System Stress reached #{level} level.")
    # In Sub-Phase 6.2, we will broadcast this to Phoenix PubSub
    # Phoenix.PubSub.broadcast(ACN.PubSub, "system_alerts", {:alert, level})
  end
end
