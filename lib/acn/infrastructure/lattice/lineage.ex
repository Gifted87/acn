defmodule ACN.Infrastructure.Lattice.Lineage do
  @moduledoc """
  Recursively resolves the ancestry of a node using Mnesia lookups and RPC validation.
  Handles conditional depth: stops traversal immediately if an ancestor is missing (Genesis/Root case).
  """
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Infrastructure.Lattice.{RPC, Ancestry, NodeInfo}

  @doc """
  Performs the Lineage Handshake with the Parent Node.
  Returns a map of ancestor PIDs: %{parent: pid, grandparent: pid, great_grandparent: pid}
  """
  def handshake(nil), do: %{parent: nil, parent_id: nil, grandparent: nil, grandparent_id: nil, great_grandparent: nil, great_grandparent_id: nil}
  def handshake(parent_pid) when is_pid(parent_pid) do
    case wait_for_handshake(parent_pid) do
      {:ok, lineage_map} -> lineage_map
      {:error, :parent_died} ->
        Logger.warning("Lineage: Parent #{inspect(parent_pid)} is already gone. Adopting orphan mode.")
        %{parent: nil, parent_id: nil, grandparent: nil, grandparent_id: nil, great_grandparent: nil, great_grandparent_id: nil}
    end
  end

  defp wait_for_handshake(parent_pid, attempt \\ 1) do
    # Fix 1B: Hard cap at 5 attempts. An unbounded retry loop was the root cause
    # of the :parent_died crash — the function would spin until OTP detected the
    # exit, then propagate it as a stop reason to the child GenServer.
    cond do
      not Process.alive?(parent_pid) ->
        Logger.warning("Lineage: Parent #{inspect(parent_pid)} is no longer alive. Orphan mode.")
        {:error, :parent_died}

      attempt > 5 ->
        Logger.warning("Lineage: Handshake retry limit reached for #{inspect(parent_pid)}. Orphan mode.")
        {:error, :parent_died}

      true ->
        try do
          case GenServer.call(parent_pid, :get_lineage, 5_000) do
            {:ok, lineage} ->
              {:ok, %{
                parent: lineage.parent_pid,
                parent_id: lineage.parent_id,
                grandparent: lineage.grandparent_pid,
                grandparent_id: lineage.grandparent_id,
                great_grandparent: lineage.great_grandparent_pid,
                great_grandparent_id: lineage.great_grandparent_id
              }}
            error ->
              Logger.warning("Lineage: Handshake returned error: #{inspect(error)}. Retrying (#{attempt}/5)...")
              Process.sleep(500)
              wait_for_handshake(parent_pid, attempt + 1)
          end
        catch
          :exit, reason ->
            Logger.warning("Lineage: Handshake RPC exit: #{inspect(reason)}. Retrying (#{attempt}/5)...")
            Process.sleep(500)
            wait_for_handshake(parent_pid, attempt + 1)
        end
    end
  end

  @doc """
  Resolves ancestors up to 3 levels deep based on the given Parent ID.
  If parent_id is nil, returns an empty Ancestry struct (Root Node).
  """
  def resolve_ancestors(nil), do: %Ancestry{}
  def resolve_ancestors(parent_id) do
    # 1. Resolve Parent
    case resolve_node(parent_id, "Parent") do
      {parent_info, grandparent_id} ->
        
        # 2. Resolve Grandparent (Conditional)
        {grandparent_info, great_grandparent_id} = 
          if grandparent_id do
            resolve_node(grandparent_id, "Grandparent")
          else
            {nil, nil}
          end

        # 3. Resolve Great-Grandparent (Conditional)
        {great_grandparent_info, _} = 
          if great_grandparent_id do
             resolve_node(great_grandparent_id, "Great-Grandparent")
          else
             {nil, nil}
          end

        %Ancestry{
          parent: parent_info,
          grandparent: grandparent_info,
          great_grandparent: great_grandparent_info
        }

      nil ->
        # Parent ID provided but not found/reachable -> Treat as Orphan/Root or Error based on strictness
        # For robustness, we log warning and return empty, allowing node to self-heal or start as root.
        Logger.warning("Lineage: Parent #{parent_id} defined but unreachable. Defaulting to Orphan state.")
        %Ancestry{}
    end
  end

  # --- Helper ---

  defp resolve_node(id, label) do
    Logger.debug("Lineage: Resolving #{label} (#{id})")
    
    # A. Look up in Registry to get location
    case NodeRegistry.lookup(id) do
      {:ok, %{pid: pid, node: node_addr, role: role, parent_id: _}} ->
         info = %NodeInfo{
           id: id,
           pid: pid,
           node_address: node_addr,
           role: role
         }

         # B. RPC to verify aliveness and get *its* parent (Next in line)
         # We ask the node for its parent_id to traverse up.
         case RPC.fast_call(pid, :get_parent_id, 2000) do
           {:ok, {:ok, next_ancestor_id}} ->
             {info, next_ancestor_id}
             
           {:ok, next_ancestor_id} when is_binary(next_ancestor_id) or is_nil(next_ancestor_id) ->
             {info, next_ancestor_id}

           {:error, reason} ->
             Logger.warning("Lineage: #{label} (#{id}) found in registry but unreachable via RPC: #{inspect(reason)}")
             nil
         end

      _ ->
         Logger.warning("Lineage: #{label} (#{id}) missing from Registry.")
         nil
    end
  end
end