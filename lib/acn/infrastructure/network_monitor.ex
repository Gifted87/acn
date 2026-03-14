defmodule ACN.Infrastructure.NetworkMonitor do
  @moduledoc """
  Monitors cluster health and enforces "let it crash" on partition.
  If a parent node disconnects, its children on this node are terminated.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("NetworkMonitor: Node Disconnected: #{node}. Initiating Partition Recovery.")
    
    # Prune Dead Remote Records (Optional but good for hygiene)
    prune_remote_records(node)

    # Terminate Orphans (Self-Termination)
    terminate_orphans_of(node)

    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("NetworkMonitor: Node Connected: #{node}")
    {:noreply, state}
  end
  
  def handle_info(_msg, state), do: {:noreply, state}

  defp prune_remote_records(dead_node) do
    # Remove records from Mnesia that are on the dead node.
    # Note: In a real Mnesia cluster, mnesia handles split brain somewhat, 
    # but for our registry table (bag/set), we might want to manually clean up transient PIDs.
    # We will assume Mnesia handles the consistency or we just delete them to be sure.
    
    # Match pattern: {table, id, pid, node, role, parent, ts}
    # We want records where node == dead_node.
    
    transaction = fn ->
      :mnesia.select(:acn_node_registry, [
        {{:acn_node_registry, :"$1", :_, :"$2", :_, :_, :_}, 
         [{:==, :"$2", dead_node}], 
         [:"$1"]}
      ])
      |> Enum.each(fn id -> 
        :mnesia.delete({:acn_node_registry, id}) 
      end)
    end
    :mnesia.transaction(transaction)
  end

  defp terminate_orphans_of(dead_node) do
    # Find LOCAL processes whose parent is on dead_node.
    my_node = node()
    
    transaction = fn ->
      # 1. Find all potential parents on dead_node (IDs)
      # (Actually we deleted them in prune_remote_records, so we should have fetched them first or do it effectively)
      # But wait, if we delete them, we can't look them up as parents.
      # So we must find orphans based on the DEAD node logic before deleting?
      # Or:
      # Iterate all LOCAL records.
      # For each, check if parent_id resolves to a node that is dead_node.
      
      # Select local records: Node == my_node
      local_records = :mnesia.select(:acn_node_registry, [
        {{:acn_node_registry, :"$1", :"$2", :"$3", :_, :"$4", :_}, 
         [{:==, :"$3", my_node}], 
         [{{:"$1", :"$2", :"$4"}}] } # Return {id, pid, parent_id}
      ])
      
      local_records
      |> Enum.each(fn {id, pid, parent_id} ->
        if parent_id do
           # Check parent location
           case :mnesia.read(:acn_node_registry, parent_id) do
             [{_, ^parent_id, _, parent_node_addr, _, _, _}] ->
               if parent_node_addr == dead_node do
                 Logger.error("NetworkMonitor: Terminating Orphan Node #{id} (Parent on #{dead_node})")
                 Process.exit(pid, :kill)
               end
             [] ->
               # Parent missing? Maybe already deleted?
               # If parent is missing, strictly we are orphaned too.
               Logger.warning("NetworkMonitor: Node #{id} has missing parent. Terminating for safety.")
               Process.exit(pid, :kill)
           end
        end
      end)
    end
    
    :mnesia.transaction(transaction)
  end
end
