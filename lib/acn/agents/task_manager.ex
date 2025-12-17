defmodule ACN.Agents.TaskManager do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.ProfileLoader
  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer

  # --- Public API ---


  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:task_manager, :task_manager)
  end

  # --- Server Callbacks ---

  defmodule State do
    defstruct [:graph, :phase, :context_snapshot, :task_id_list, :plan_id, :node_metadata]
  end

  @impl true
  def init(_) do
    # Initialize a new directed graph
    graph = Graph.new(type: :directed)
    state = %State{
      graph: graph,
      phase: :idle,
      task_id_list: [],  # Cache for Linker
      plan_id: nil,
      node_metadata: %{}
    }
    {:ok, state}
  end

  # --- Trigger: Start # --- Casts ---

  # --- Morphic State Handlers ---
  @impl true
  def handle_cast({:wake}, state) do
    Logger.info("TaskManager: Waking up (Morphic State: INTERMEDIATE). Ready to plan.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sleep}, state) do
    Logger.info("TaskManager: Entering Sleep Mode (Morphic State: LEAF).")
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_cast({:decompose, context, _rules}, state) do
    Logger.info("TaskManager: Received Decomposition Request. Starting Phase 1 (Slicer).")
    
    # 1. Update State
    state = %{state | 
      phase: :slicing, 
      context_snapshot: context,
      # Clear previous graph if reusing?
      graph: Graph.new(type: :directed),
      task_id_list: [],
      node_metadata: %{}
    }

    # 2. Run Slicer Logic
    run_slicer_phase(context, state)
    
    # Queue transition after tools are processed
    # Queue transition logic handled inside run_slicer_phase

    {:noreply, state}
  end

  # --- Tool Actions (Processed from Mailbox) ---

  @impl true
  def handle_cast({:add_node, uuid, metadata}, state) do
    Logger.debug("TaskManager: Adding Node #{uuid}")
    
    new_graph = Graph.add_vertex(state.graph, uuid)
    new_list = [uuid | state.task_id_list]
    new_meta = Map.put(state.node_metadata || %{}, uuid, metadata)
    
    {:noreply, %{state | graph: new_graph, task_id_list: new_list, node_metadata: new_meta}}
  end

  @impl true
  def handle_cast({:add_dependency, provider, consumer}, state) do
    Logger.debug("TaskManager: Linking #{provider} -> #{consumer}")
    
    new_graph = Graph.add_edge(state.graph, provider, consumer)
    {:noreply, %{state | graph: new_graph}}
  end

  # --- Phase Transitions ---

  @impl true
  def handle_cast({:next_phase, :failed}, state) do
    Logger.error("TaskManager: Critical Phase Failure. Staying in :failed state to prevent restart loop.")
    # We do not stop the GenServer, just park it in :failed state.
    # Intervention (God Mode) via Dashboard would be needed to reset.
    {:noreply, %{state | phase: :failed}}
  end

  @impl true
  def handle_cast({:next_phase, :linking}, state) do
    Logger.info("TaskManager: Transitioning to Phase 2 (Linker). Node Count: #{length(state.task_id_list)}")
    
    run_linker_phase(state.task_id_list, state)
    
         GenServer.cast(self(), {:next_phase, :validating})
         {:noreply, %{state | phase: :linking}}
      end

  @impl true
  def handle_cast({:next_phase, :validating}, state) do
    Logger.info("TaskManager: Transitioning to Phase 3 (Validator).")
    
    case validate_graph(state.graph) do
      :ok ->
        Logger.info("TaskManager: Graph Validated. Proceeding to Scheduler.")
        GenServer.cast(self(), {:next_phase, :scheduling})
        {:noreply, %{state | phase: :validating}}
        
      {:error, reason} ->
        Logger.error("TaskManager: Planning Failed Validation: #{inspect(reason)}")
        # Failure recovery? For now, halt.
        {:noreply, %{state | phase: :failed}}
    end
  end

  @impl true
  def handle_cast({:next_phase, :scheduling}, state) do
    Logger.info("TaskManager: Transitioning to Phase 4 (Scheduler).")
    
    # Topological Sort
    case Graph.topsort(state.graph) do
      sorted_ids when is_list(sorted_ids) ->
        
        # Retrieve metadata from state and atomize keys for struct-like access
        execution_steps = Enum.map(sorted_ids, fn id ->
           meta = Map.get(state.node_metadata, id, %{})
           # Convert string keys to atoms so Controller can use task.id notation
           atomized_meta = atomize_keys(meta)
           Map.put(atomized_meta, :id, id)
        end)
        
        # PARALLEL BATCHING: Group tasks by DAG layers
        # Tasks with no dependencies go in batch 1
        # Tasks that only depend on batch 1 go in batch 2, etc.
        batches = compute_parallel_batches(state.graph, execution_steps)
        
        plan = %{
          batches: batches,
          graph_export: Graph.to_edgelist(state.graph)
        }
        
        Logger.info("TaskManager: Plan Ready. Batches: #{length(batches)}. Dispatching to Controller.")
        ACN.Core.Router.route({:plan_ready, plan}, {:local, :controller})
        
        {:noreply, %{state | phase: :scheduled}}
        
      false -> # Cycle detected
        Logger.error("TaskManager: Cycle detected during sort!")
        {:noreply, %{state | phase: :failed}}
    end
  end

  # --- Internal Logic ---

  defp run_slicer_phase(context, _parent_state) do
    intent = 
      get_in(context, ["task_assignment", "description"]) ||
      context["description"] ||
      "Unknown Task"
    
    case ProfileLoader.load("tm_slicer", %{intent: intent}) do
      {:ok, profile} ->
        buffer = ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
        config = %{adapter: adapter, stop_after_tools: true}
        allowed_tools = profile["allowed_tools"]
        
        # --- FIX START ---
        case Pipeline.run(buffer, allowed_tools, config) do
           {:ok, _, _} ->
              Logger.info("Slicer phase completed.")
              # Small delay to allow async tool cast messages to be processed
              Process.sleep(100)
              GenServer.cast(self(), {:next_phase, :linking})
              
           {:error, :max_turns_exceeded} ->
              # Small models get chatty and hit max_turns even after successfully calling tools
              # Check if any tasks were actually added before failing
              Process.sleep(100)  # Let pending tool casts complete
              
              current_state = :sys.get_state(self())
              task_count = length(current_state.task_id_list)
              
              if task_count > 0 do
                Logger.warning("Slicer hit max_turns but #{task_count} tasks were added. Proceeding.")
                GenServer.cast(self(), {:next_phase, :linking})
              else
                Logger.error("Slicer hit max_turns with no tasks added. Failing.")
                GenServer.cast(self(), {:next_phase, :failed})
              end
              
           {:error, reason} ->
              Logger.error("Slicer AI Failed: #{inspect(reason)}")
              GenServer.cast(self(), {:next_phase, :failed})
        end
        # --- FIX END ---
        
      {:error, reason} ->
        Logger.error("Failed to load Slicer profile: #{inspect(reason)}")
    end
  end
  
  defp run_linker_phase(node_ids, state) do
    # Format tasks as single line to avoid YAML indentation conflicts
    node_list_str = 
      Enum.map_join(node_ids, " | ", fn id ->
        meta = Map.get(state.node_metadata, id, %{})
        "#{id} (#{meta["type"]}) - #{meta["description"]} -> Produces: #{meta["output_directive"]}"
      end)
    
    case ProfileLoader.load("tm_linker", %{node_list: node_list_str}) do
      {:ok, profile} ->
        buffer = ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
        config = %{adapter: adapter, stop_after_tools: true}
        allowed_tools = profile["allowed_tools"]
        
        Logger.debug("Running Linker Pipeline...")
        Pipeline.run(buffer, allowed_tools, config)
        
      {:error, reason} ->
        Logger.error("Failed to load Linker profile: #{inspect(reason)}")
    end
  end
  
  defp validate_graph(graph) do
    if Graph.is_acyclic?(graph) do
      :ok
    else
      {:error, :cycle_detected}
    end
  end

  # Compute parallel batches based on DAG topology
  # Returns [[batch1_tasks], [batch2_tasks], ...]
  defp compute_parallel_batches(graph, execution_steps) do
    # Build a map of task_id -> task_metadata
    task_map = Map.new(execution_steps, fn step -> {step.id, step} end)
    
    # Compute in-degrees for all tasks
    in_degrees = 
      Enum.reduce(execution_steps, %{}, fn step, acc ->
        # Count incoming edges
        in_degree = Graph.in_degree(graph, step.id)
        Map.put(acc, step.id, in_degree)
      end)
    
    # Iteratively build batches
    build_batches(graph, task_map, in_degrees, [])
  end
  
  defp build_batches(_graph, _task_map, in_degrees, batches) when map_size(in_degrees) == 0 do
    Enum.reverse(batches)
  end
  
  defp build_batches(graph, task_map, in_degrees, batches) do
    # Find all tasks with in_degree == 0 (no dependencies)
    ready_ids = 
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _} -> id end)
    
    if ready_ids == [] do
      # Cycle detected or error - fallback to remaining tasks in single batch
      remaining_tasks = 
        in_degrees
        |> Map.keys()
        |> Enum.map(fn id -> Map.get(task_map, id) end)
      Enum.reverse([remaining_tasks | batches])
    else
      # Create batch from ready tasks
      batch = Enum.map(ready_ids, fn id -> Map.get(task_map, id) end)
      
      # Remove these tasks from in_degrees
      new_in_degrees = Map.drop(in_degrees, ready_ids)
      
      # Decrement in-degrees for tasks that depended on completed tasks
      new_in_degrees = 
        Enum.reduce(ready_ids, new_in_degrees, fn completed_id, acc ->
          # Get all tasks that depend on this completed task
          dependents = Graph.out_neighbors(graph, completed_id)
          
          Enum.reduce(dependents, acc, fn dep_id, acc2 ->
            Map.update(acc2, dep_id, 0, fn deg -> max(0, deg - 1) end)
          end)
        end)
      
      build_batches(graph, task_map, new_in_degrees, [batch | batches])
    end
  end
  
  # Helper: Convert string keys to atoms to enable dot notation access
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}  # Keep atom keys as-is
    end)
  rescue
    ArgumentError ->
      # If atom doesn't exist, use safe conversion
      Map.new(map, fn
        {k, v} when is_binary(k) -> 
          # Only atomize known safe keys
          safe_key = case k do
            "id" -> :id
            "description" -> :description
            "type" -> :type
            "output_directive" -> :output_directive
            "name" -> :name
            _ -> k  # Keep as string if unknown
          end
          {safe_key, v}
        {k, v} -> {k, v}
      end)
  end


end
