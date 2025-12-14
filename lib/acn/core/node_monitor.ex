defmodule ACN.Core.NodeMonitor do
  use GenServer
  require Logger

  @registry_table :acn_node_registry_v2

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    {:ok, %{}}
  end

  def monitor(pid, node_id) do
    GenServer.cast(__MODULE__, {:monitor, pid, node_id})
  end

  def handle_cast({:monitor, pid, node_id}, state) do
    Process.monitor(pid)
    # Store mapping ref -> node_id if needed, or rely on info msg?
    # DOWN msg contains ref and pid (object).
    # We map PID -> NodeID?
    # But if PID is reused (rare but possible with high churn)?
    # Use ref mapping in state: %{ref => node_id}

    # We assume 'monitor' returns a ref
    # Wait, Process.monitor returns ref.
    # But here we monitored inside handle_cast. We don't have the ref from caller.
    # We must store it.

    # Correction: We just monitored.
    # State update needed.
    {:noreply, Map.put(state, pid, node_id)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.fetch(state, pid) do
      {:ok, node_id} ->
        Logger.info("NodeMonitor: Detected death of #{node_id} (#{inspect(pid)}). Pruning registry.")

        # Prune Mnesia
        # Option A: Delete row
        # Option B: Mark as dead (update PID to nil?)
        # Directive says "remove or tag... as Dead".
        # Let's delete to keep table clean for now.
        transaction = fn ->
          :mnesia.delete({@registry_table, node_id})
        end
        :mnesia.transaction(transaction)

        {:noreply, Map.delete(state, pid)}

      :error ->
        # Unknown PID (maybe from before restart?)
        {:noreply, state}
    end
  end
end
