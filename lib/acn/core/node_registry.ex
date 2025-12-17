defmodule ACN.Core.NodeRegistry do
  @moduledoc """
  Distributed Registry using Mnesia.
  Maps Node UUID -> metadata (PID, Address, Role, Parent).
  Replaces local Elixir Registry.
  """
  require Logger

  @table :acn_node_registry_v2
  # @table :acn_node_registry


  # --- Public API ---

  def child_spec do
    # No process needed; Mnesia is the process.
    # We return an ignore spec to satisfy supervision tree requirements.
    %{
      id: __MODULE__,
      start: {Function, :identity, [:ignore]},
      type: :worker
    }
  end

  @doc """
  Registers a new node in the distributed registry.
  Must be called synchronously before the node logic starts (e.g. in SupervisorWrapper).
  """
  def register_node(id, pid, role, parent_id, metadata \\ %{}) do
    Logger.info("NodeRegistry.register_node called for #{inspect id}, pid: #{inspect pid} by #{inspect self()}")
    # Write to Mnesia
    node_addr = if pid, do: node(pid), else: node()

    row = {
      @table,
      id,       # Key
      pid,      # PID
      node_addr,# Address
      role,
      parent_id,
      System.system_time(:second),
      metadata
    }

    transaction = fn ->
      :mnesia.write(row)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates metadata for an existing node.
  """
  def update_metadata(id, metadata_update) do
    transaction = fn ->
      case :mnesia.read(@table, id) do
        [{table, ^id, pid, node, role, parent, created, old_meta}] ->
          new_meta = Map.merge(old_meta || %{}, metadata_update)
          :mnesia.write({table, id, pid, node, role, parent, created, new_meta})
        [] ->
          :mnesia.abort(:not_found)
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} -> :ok
      err -> err
    end
  end

  # --- Data Access ---

  @doc """
  Looks up a node by ID.
  Returns {:ok, %{pid: pid, node: address, ...}} or {:error, :not_found}.
  """
  def lookup(id) do
    # Dirty read for speed (RAM access)
    result = case :mnesia.dirty_read(@table, id) do
      [{_table, _id, pid, node_addr, role, parent_id, _ts, metadata}] ->
        {:ok, %{
          pid: pid,
          node: node_addr,
          role: role,
          parent_id: parent_id,
          metadata: metadata
        }}

      # Handle legacy/migration case where record might have 6 elements?
      # Mnesia might return the tuple as is.
      # If schema changed but data didn't transform, reading might crash or return old tuple.
      # We assume clean slate or successful migration for now.

      [] -> {:error, :not_found}
    end
    # Logger.debug("NodeRegistry.lookup(#{inspect id}) -> #{inspect result}")
    result
  end

  # Helper for existing code compatibility?
  # Existing code calls NodeRegistry.lookup(name, id)
  # Only 'id' matters now. 'name' (:supervisor etc) is implicit in context.
  # We should support simple lookup by id.

  # Handling Via Tuple:
  # Older code: name: via_tuple(node_id)
  # GenServer calls Registry.
  # We can't easily shim Mnesia into via_tuple logic without a custom registry module implementation
  # that implements the :via callbacks (register_name, whereis_name, etc).
  # Implementing the Via behavior for Mnesia is the best way to keep existing code working!

  # --- Elixir Registry (Via) Behavior ---

  def whereis_name({_name_atom, id}) do
    # Logger.debug("whereis_name(#{inspect id})")
    # We ignore the atom name (:supervisor) and route purely by ID
    case lookup(id) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          :undefined
        end

      _ -> :undefined
    end
  end

  def register_name({name_atom, id}, pid) do
    Logger.debug("NodeRegistry: register_name called for #{inspect name_atom}/#{inspect id} by PID #{inspect pid}")
    transaction = fn ->
      case :mnesia.read(@table, id) do
        [{table, ^id, old_pid, _addr, role, parent, created, meta}] ->
           # Check if valid PID and Alive
           is_alive = is_pid(old_pid) && Process.alive?(old_pid)

           if is_alive and old_pid != pid do
             Logger.error("CONFLICT: ID #{inspect(id)} owned by ALIVE #{inspect(old_pid)}. New: #{inspect(pid)}")
             :mnesia.abort(:already_registered)
           else
             Logger.debug("Overwriting #{inspect id} to #{inspect pid}")
             :mnesia.write({table, id, pid, node(pid), role, parent, created, meta})
           end

        [] ->
           Logger.debug("Writing NEW #{inspect id} -> #{inspect pid}")
           :mnesia.write({@table, id, pid, node(pid), :leaf, nil, System.system_time(:second), %{}})
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} ->
        ACN.Core.NodeMonitor.monitor(pid, id)
        :yes
      {:aborted, :already_registered} ->
        :no
      other ->
        Logger.error("Register transaction failed: #{inspect other}")
        :no
    end
  end

  def unregister_name({_name_atom, id}) do
    :mnesia.dirty_delete(@table, id)
  end

  def send({_name_atom, id}, msg) do
    case lookup(id) do
      {:ok, %{pid: pid}} -> Kernel.send(pid, msg)
      _ -> :badarg
    end
  end

  # Allow simple ID usage too via {:via, ACN.Core.NodeRegistry, {name, id}}
  def via_tuple(name, id \\ nil) do
    {:via, __MODULE__, {name, id}}
  end
end
