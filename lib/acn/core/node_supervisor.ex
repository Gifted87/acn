defmodule ACN.Core.NodeSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  def start_child_node(args) do
    # 1. Ask ClusterManager for best target
    target_node = ACN.Infrastructure.ClusterManager.select_best_target()
    
    # 2. Dispatch
    if target_node == node() do
      spawn_local_child(args)
    else
      Logger.info("NodeSupervisor: Dispatching spawn to remote node #{target_node}")
      # RPC Call to spawn_local_child on remote node
      # We assume the code base is identical on all nodes.
      case :rpc.call(target_node, __MODULE__, :spawn_local_child, [args]) do
        {:ok, pid} -> {:ok, pid}
        error -> 
           Logger.error("NodeSupervisor: Remote spawn failed on #{target_node}: #{inspect(error)}. Fallback to local.")
           spawn_local_child(args)
      end
    end
  end

  @doc """
  Executes the actual DynamicSupervisor start_child on the local node.
  Can be called via RPC from a remote parent.
  """
  def spawn_local_child(args) do
    # args must contain keys like :task (which serves as ID), :task_type, :parent_node
    # args[:task] is usually an ID string "task_1"
    
    # We verify args has what we need, at least an ID
    if is_nil(args[:task]) and is_nil(args[:id]), do: raise "Cannot spawn child without :task or :id"

    # Support new ID key
    id = args[:task] || args[:id]
    parent_id = args[:parent_node] || args[:parent] # generic support
    
    # Legacy Registration (Only if not using LatticeRegistry self-registration?)
    # For now, we leave this for backward compatibility for old agents, 
    # but new agents register themselves in init().
    if args[:legacy_register] do
      role = if args[:task_type] == :manager, do: :intermediate, else: :leaf
      ACN.Core.NodeRegistry.register_node(id, nil, role, parent_id)
    end

    # 2. Spawn Child
    child_module = args[:child_module] || ACN.Agents.SupervisorAgent
    spec = {child_module, args}
    
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
