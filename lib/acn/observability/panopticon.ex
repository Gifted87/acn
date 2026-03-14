defmodule ACN.Observability.Panopticon do
  @moduledoc """
  HSG Phase 2 — The In-Memory Panopticon.

  This is a singleton GenServer that acts as the real-time, in-memory nervous system
  of the ACN observability layer. It subscribes to the global PubSub stream (`acn:telemetry:all`),
  receives `MicroDBC` structs emitted in Phase 1, and inserts them into an Erlang `:digraph`.

  The `:digraph` maintains the relational "Intent vs. Reality" causal web.
  """
  use GenServer
  require Logger
  alias ACN.Observability.MicroDBC

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a snapshot of the current graph as a map of vertices and edges.
  Useful for API inspection.
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Finds all paths between a planned intent node and its realized execution node.
  """
  def find_causation(intent_id, reality_id) do
    GenServer.call(__MODULE__, {:find_path, intent_id, reality_id})
  end

  @doc """
  Allow the TaskManager to inject "Intent" edges into the graph BEFORE they happen.
  """
  def inject_intent(parent_node_id, batch_index, planned_tasks) do
    GenServer.cast(__MODULE__, {:inject_intent, parent_node_id, batch_index, planned_tasks})
  end

  @doc """
  Resets the graph. Use only in tests.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # Create the ETS-backed directed graph.
    # [:cyclic] allows recursive retry loops to be modeled safely.
    graph = :digraph.new([:cyclic])

    # Subscribe to the global HSG streams
    Phoenix.PubSub.subscribe(ACN.PubSub, MicroDBC.global_topic())
    Phoenix.PubSub.subscribe(ACN.PubSub, "acn:intent:plan")

    Logger.info("Panopticon: Started. Graph initialized. Subscribed to #{MicroDBC.global_topic()} and acn:intent:plan")

    {:ok, %{graph: graph}}
  end

  @impl true
  def handle_info({:plan_published, %{tasks: tasks}}, state) do
    # Represents the "Blueprint" layer of the shadow graph.
    Enum.each(tasks, fn task ->
      id = task[:node_id] || task["node_id"]
      if id do
        :digraph.add_vertex(state.graph, id, %{type: :planned_agent, id: id, task: task})
        # If there are dependencies, add edges
        deps = task[:dependencies] || task["dependencies"] || []
        Enum.each(deps, fn dep_id ->
          v1 = :digraph.add_vertex(state.graph, dep_id, %{type: :agent, id: dep_id})
          v2 = id
          :digraph.add_edge(state.graph, v1, v2, %{type: :intent})
        end)
      end
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:telemetry_event, %MicroDBC{} = dbc}, state) do
    require Logger
    Logger.info("Panopticon received Telemetry: #{dbc.event_id} from #{dbc.node_id}")

    # Represents the "Reality" layer.
    node_id = dbc.node_id
    
    # 1. UPSERT VERTEX (Node Identity)
    vertex_data = %{
      type: :agent,
      id: node_id,
      last_phase: dbc.phase_to,
      stress: get_in(dbc.autonomic, [:stress_level])
    }
    :digraph.add_vertex(state.graph, node_id, vertex_data)

    # 2. UPSERT VERTEX (Event Hash)
    # The hash itself becomes a vertex representing a point in time.
    event_vertex_data = %{
      type: :event,
      hash: dbc.hash,
      dbc: dbc
    }
    :digraph.add_vertex(state.graph, dbc.hash, event_vertex_data)

    # 3. ADD CAUSAL EDGES
    # Edge: Node -> emitted -> Event
    :digraph.add_edge(state.graph, node_id, dbc.hash, %{type: :emission})

    # Edge: Event -> prev_hash -> Event (Cryptographic chain)
    if dbc.prev_hash do
      :digraph.add_edge(state.graph, dbc.hash, dbc.prev_hash, %{type: :temporal_predecessor})
    end

    # Edge: Event -> trace_parent (Span causality)
    # Note: We use TraceID + Span causality. If this span has a parent (implying another agent 
    # triggered it), we connect them dynamically via EdgeClassifier.
    
    edge_label = ACN.Observability.EdgeClassifier.classify(dbc)
    
    # Optional Semantic Edges based on type
    case edge_label.type do
      :execution_start -> 
        Logger.debug("Panopticon: Caught execution start. Coloring edge :active")
      :success ->
        Logger.debug("Panopticon: Caught success. Coloring edge :green")
      :failure ->
        Logger.debug("Panopticon: Caught failure. Coloring edge :red")
      _ -> :ok
    end

    # 4. ASYNC PERSISTENCE
    # Offload the Mnesia commit so the Panopticon inbox never blocks
    Task.start(fn ->
      ACN.Observability.Persistence.persist(dbc)
    end)

    # 5. ASYNC SHADOW WRITER
    # Offload the spatial text files (.shadow)
    Task.start(fn ->
      ACN.Observability.ShadowWriter.write(dbc)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, _result}, state) do
    # Catch results from Task.Supervisor.async_nolink
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Catch task termination messages
    {:noreply, state}
  end

  @impl true
  def handle_cast({:inject_intent, parent_id, batch_index, planned_tasks}, state) do
    # Represents the "Blueprint" layer of the shadow graph.
    # The parent (Intermediate node) intends for these child nodes to execute.
    parent_vertex = :digraph.add_vertex(state.graph, parent_id, %{type: :agent, id: parent_id})

    Enum.each(planned_tasks, fn task ->
      # Task ID is typically the child node ID
      child_id = task.id || task["id"]
      if child_id do
        child_vertex = :digraph.add_vertex(state.graph, child_id, %{type: :planned_agent, id: child_id, task: task})
        
        # Edge weight 0 = Intent (Future)
        edge_label = %{type: :intent, batch: batch_index, raw_task: task}
        :digraph.add_edge(state.graph, parent_vertex, child_vertex, edge_label)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    vertices = :digraph.vertices(state.graph)
    edges = :digraph.edges(state.graph)

    v_data = Enum.map(vertices, fn v -> 
      {_, label} = :digraph.vertex(state.graph, v)
      {v, label}
    end)
    
    e_data = Enum.map(edges, fn e -> 
      {edge, v1, v2, label} = :digraph.edge(state.graph, e)
      %{id: edge, from: v1, to: v2, label: label}
    end)

    {:reply, %{vertices: v_data, edges: e_data}, state}
  end

  @impl true
  def handle_call(:reset, _from, %{graph: graph} = state) do
    # Clear the digraph
    :digraph.delete(graph)
    new_graph = :digraph.new([:cyclic])
    {:reply, :ok, %{state | graph: new_graph}}
  end

  @impl true
  def handle_call({:find_path, from, to}, _from, state) do
    path = :digraph.get_path(state.graph, from, to)
    {:reply, path, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Prevent memory leaks when GenServer shuts down
    if state.graph, do: :digraph.delete(state.graph)
  end
end
