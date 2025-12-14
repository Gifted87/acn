defmodule ACN.Infrastructure.Lattice.Lineage do
  @moduledoc """
  Recursively resolves the ancestry of a node using Mnesia lookups and RPC validation.
  """
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Infrastructure.Lattice.{RPC, Ancestry, NodeInfo}

  @doc """
  Resolves ancestors up to 3 levels deep.
  Raises if a required parent is unreachable (Genetic Dependency).
  """
  def resolve_ancestors(current_node_id) do
    # 1. Get Immediate Parent ID from Mnesia (Source of Truth for topology)
    case NodeRegistry.lookup(current_node_id) do
      {:ok, %{parent_id: parent_id}} when not is_nil(parent_id) ->
        
        # 2. Resolve Parent
        {parent_info, grandparent_id} = fetch_ancestor_and_next(parent_id, "Parent")
        
        # 3. Resolve Grandparent (if exists)
        {grandparent_info, great_grandparent_id} = 
          if grandparent_id do
            fetch_ancestor_and_next(grandparent_id, "Grandparent")
          else
            {nil, nil}
          end

        # 4. Resolve Great-Grandparent (if exists)
        {great_grandparent_info, _} = 
          if great_grandparent_id do
             fetch_ancestor_and_next(great_grandparent_id, "Great-Grandparent")
          else
             {nil, nil}
          end

        %Ancestry{
          parent: parent_info,
          grandparent: grandparent_info,
          great_grandparent: great_grandparent_info
        }

      _ ->
        # Root node or not found
        %Ancestry{}
    end
  end

  # --- Helper ---

  defp fetch_ancestor_and_next(id, relationship_label) do
    Logger.debug("Lineage: Resolving #{relationship_label} (#{id})")
    
    # A. Look up in Registry to get location
    case NodeRegistry.lookup(id) do
      {:ok, %{pid: pid, node: node_addr, role: role, parent_id: _mnesia_parent_id}} ->
         info = %NodeInfo{
           id: id,
           pid: pid,
           node_address: node_addr,
           role: role
         }

         # B. RPC to verify aliveness and get *its* parent (Next in line)
         # We prioritize the RPC result for the next link to prove connectivity.
         case RPC.fast_call(pid, :get_parent_id) do
           {:ok, {:ok, next_ancestor_id}} ->
             {info, next_ancestor_id}
             
           {:ok, next_ancestor_id} when is_binary(next_ancestor_id) or is_nil(next_ancestor_id) ->
             # Handle implicit :ok wrap or raw return
             {info, next_ancestor_id}

           {:error, reason} ->
             Logger.error("Lineage: Critical Failure! #{relationship_label} (#{id}) is unreachable: #{inspect(reason)}")
             raise "Lineage Broken: #{relationship_label} Unreachable"
         end

      {:error, :not_found} ->
         Logger.error("Lineage: Critical Failure! #{relationship_label} (#{id}) missing from Registry.")
         raise "Lineage Broken: #{relationship_label} Missing"
    end
  end
end
