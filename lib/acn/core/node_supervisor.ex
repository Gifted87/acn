defmodule ACN.Core.NodeSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
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
    if is_nil(args[:task]), do: raise "Cannot spawn child without :task ID"

    # 1. Register Metadata in Mnesia (Distributed Source of Truth)
    # The register logic is valid regardless of who calls it, but usually done by Parent?
    # Actually, NodeRegistry.register_node writes to Mnesia. Mnesia is shared/replicated.
    # So it doesn't matter *where* we write it, as long as write succeeds.
    # Ideally, we write it *before* spawn to reserve the ID.
    
    id = args[:task]
    parent_id = args[:parent_node]
    role = if args[:task_type] == :manager, do: :intermediate, else: :leaf
    
    ACN.Core.NodeRegistry.register_node(id, nil, role, parent_id)

    # 2. Spawn Child
    # Let's assume we pass the WHOLE args map as the argument to start_link
    spec = {ACN.Agents.SupervisorAgent, args}
    
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
