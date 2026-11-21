defmodule ACN.Observability.Panopticon do
  @moduledoc """
  HSG Phase 2 — The In-Memory Panopticon.

  Maintains two separate stores:

  1. **Node Table** — ETS table `:acn_hsg_nodes` keyed by `mat_path`.
     Only ever contains real ACN agent nodes. Updated on every telemetry event.
     This is the authoritative source for the dashboard snapshot.

  2. **Causal Graph** — Erlang `:digraph` for internal causality, path-finding,
     and chain-verification. NOT exposed to the dashboard directly.

  This separation ensures the dashboard gets clean, accurate data without
  filtering artifacts like SHA-256 hash vertices or `:nonode@nohost` phantom nodes.
  """
  use GenServer
  require Logger
  alias ACN.Observability.MicroDBC

  @node_table :acn_hsg_nodes
  @id_index   :acn_hsg_id_index  # flat_node_id → full_mat_path

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the clean node-state snapshot for the dashboard.
  Only real agent nodes, current state. Fast ETS read.
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Seed a known node before it emits telemetry, so it appears
  in the dashboard the moment it is spawned.
  """
  def register_node(attrs) do
    GenServer.cast(__MODULE__, {:register_node, attrs})
  end

  @doc """
  Inject planned-task intent edges so children appear as "initialized"
  before their first telemetry event arrives.
  """
  def inject_intent(parent_mat_path, batch_index, planned_tasks) do
    GenServer.cast(__MODULE__, {:inject_intent, parent_mat_path, batch_index, planned_tasks})
  end

  @doc """
  Finds all paths between two nodes in the causal graph.
  """
  def find_causation(from_id, to_id) do
    GenServer.call(__MODULE__, {:find_path, from_id, to_id})
  end

  @doc "Resets state. Use in tests only."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Clean ETS node table — keyed by mat_path
    table = :ets.new(@node_table, [:set, :protected, :named_table, read_concurrency: true])

    # Reverse-lookup index: flat_node_id → full mat_path
    # Needed because MicroDBC.mat_path may be flat ("dependency_management")
    # while the ETS key was seeded as "root.dependency_management".
    index = :ets.new(@id_index, [:set, :protected, :named_table, read_concurrency: true])

    # Causal graph — for path-finding only
    graph = :digraph.new([:cyclic])

    Phoenix.PubSub.subscribe(ACN.PubSub, MicroDBC.global_topic())
    Phoenix.PubSub.subscribe(ACN.PubSub, "acn:intent:plan")

    Logger.info("Panopticon: Started. Node table: #{inspect(table)}. Subscribed to #{MicroDBC.global_topic()} and acn:intent:plan")

    {:ok, %{graph: graph, table: table, index: index}}
  end

  # ── Telemetry Events ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:telemetry_event, %MicroDBC{} = dbc}, state) do
    mat_path = dbc.mat_path || dbc.node_id

    # Reject phantom/hash nodes: valid mat_paths are dot-separated words
    # (e.g. "root", "root.dependency_management") not 64-char hex strings
    # and not Erlang node names like "nonode@nohost".
    if valid_mat_path?(mat_path) do
      upsert_node(state.table, state.index, dbc)
      update_causal_graph(state.graph, dbc)
      Logger.info("Panopticon: Updated node #{mat_path} → #{dbc.phase_to}")
    else
      Logger.debug("Panopticon: Skipped phantom node '#{mat_path}' (not a valid mat_path)")
    end

    # Persist and shadow-write are still done regardless
    Task.start(fn -> ACN.Observability.Persistence.persist(dbc) end)
    Task.start(fn -> ACN.Observability.ShadowWriter.write(dbc) end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:plan_published, %{tasks: tasks}}, state) do
    Enum.each(tasks, fn task ->
      id = task[:node_id] || task["node_id"]
      if id && valid_mat_path?(to_string(id)) do
        ensure_node(state.table, to_string(id), :initialized)
      end
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, _result}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ── Casts ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:register_node, attrs}, state) do
    mat_path = to_string(attrs[:mat_path] || attrs[:node_id] || "")
    if valid_mat_path?(mat_path) do
      record = build_node_record(mat_path, attrs)
      :ets.insert(state.table, {mat_path, record})
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:inject_intent, parent_mat_path, _batch_index, planned_tasks}, state) do
    # Ensure parent exists
    if valid_mat_path?(to_string(parent_mat_path)) do
      ensure_node(state.table, to_string(parent_mat_path), :running)
    end

    # Seed each child as "initialized" so they show up immediately
    planned_tasks =
      cond do
        is_map(planned_tasks) -> [planned_tasks]
        is_list(planned_tasks) -> planned_tasks
        true -> []
      end

    Enum.each(planned_tasks, fn task ->
      task = if is_map(task), do: task, else: %{}
      child_id = to_string(task[:id] || task["id"] || task[:node_id] || task["node_id"] || "")
      if child_id != "" && valid_mat_path?(child_id) do
        # ALWAYS build the full hierarchical path: "root.child_id", "parent.child_id", etc.
        # Never store a child as a flat entry with no parent prefix, or it will
        # render as a root-tier node with depth=0.
        parent_prefix = to_string(parent_mat_path || "root")
        child_mat_path = "#{parent_prefix}.#{child_id}"

        ensure_node(state.table, child_mat_path, :initialized)

        # Register in the reverse-lookup index so flat mat_path events
        # from MicroDBC ("dependency_management") resolve to "root.dependency_management"
        :ets.insert(state.index, {child_id, child_mat_path})

        # Also wire in causal graph
        :digraph.add_vertex(state.graph, to_string(parent_mat_path),
          %{type: :agent, id: parent_mat_path})
        :digraph.add_vertex(state.graph, child_mat_path,
          %{type: :planned_agent, id: child_mat_path})
        :digraph.add_edge(state.graph, to_string(parent_mat_path), child_mat_path,
          %{type: :intent})
      end
    end)

    {:noreply, state}
  end

  # ── Calls ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:snapshot, _from, state) do
    vertices = :ets.tab2list(state.table)

    # Build nodes list from ETS
    nodes =
      Enum.map(vertices, fn {mat_path, record} ->
        parts = String.split(mat_path, ".")
        depth = length(parts) - 1
        parent_path = if depth > 0, do: Enum.take(parts, depth) |> Enum.join("."), else: nil

        tier =
          cond do
            depth == 0 -> "root"
            depth == 1 -> "intermediate"
            true -> "leaf"
          end

        %{
          id:         mat_path,
          mat_path:   mat_path,
          parent_id:  parent_path,
          depth:      depth,
          node_tier:  tier,
          type:       to_string(record[:node_tier] || "agent"),
          last_phase: to_string(record[:phase] || record[:last_phase] || "pending"),
          stress:     record[:stress] || 0.0
        }
      end)

    # Build edges from ETS node parent relationships
    edges =
      nodes
      |> Enum.filter(& &1.parent_id)
      |> Enum.map(fn node ->
        %{
          id:   "#{node.parent_id}→#{node.mat_path}",
          from: node.parent_id,
          to:   node.mat_path,
          type: "hierarchy"
        }
      end)

    {:reply, %{vertices: nodes, edges: edges}, state}
  end

  @impl true
  def handle_call(:reset, _from, %{graph: graph, table: table, index: index} = state) do
    :ets.delete_all_objects(table)
    :ets.delete_all_objects(index)
    :digraph.delete(graph)
    new_graph = :digraph.new([:cyclic])
    {:reply, :ok, %{state | graph: new_graph}}
  end

  @impl true
  def handle_call({:find_path, from, to}, _from, state) do
    {:reply, :digraph.get_path(state.graph, from, to), state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.graph, do: :digraph.delete(state.graph)
    # ETS named table is cleaned up automatically when the owning process dies
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # A valid mat_path is a dot-separated identifier — each segment is:
  # alphanumeric + underscores only, max 80 chars per segment.
  # Rejects: SHA-256 hashes (64-char hex), Erlang node names ("nonode@nohost"),
  # UUIDs, and anything with @ or spaces.
  defp valid_mat_path?(nil), do: false
  defp valid_mat_path?(""), do: false
  defp valid_mat_path?(s) when is_binary(s) do
    segments = String.split(s, ".")
    Enum.all?(segments, fn seg ->
      byte_size(seg) > 0 and
      byte_size(seg) <= 80 and
      String.match?(seg, ~r/^[a-zA-Z][a-zA-Z0-9_]*$/)
    end)
  end
  defp valid_mat_path?(_), do: false

  defp upsert_node(table, index, %MicroDBC{} = dbc) do
    raw_path = dbc.mat_path || dbc.node_id

    # Resolve flat node IDs to their full mat_path via the intent index.
    # e.g. "dependency_management" → "root.dependency_management" (if seeded by inject_intent)
    canon_path =
      case :ets.lookup(index, raw_path) do
        [{^raw_path, full_path}] -> full_path
        [] -> raw_path  # No mapping known; use as-is (e.g. "root" is already canonical)
      end

    mat_path = canon_path
    existing = case :ets.lookup(table, mat_path) do
      [{^mat_path, rec}] -> rec
      [] -> %{}
    end

    stress = get_in(dbc.autonomic, [:stress_level]) || existing[:stress] || 0.0

    updated =
      existing
      |> Map.put(:mat_path, mat_path)
      |> Map.put(:node_id, dbc.node_id)
      |> Map.put(:phase, to_string(dbc.phase_to))
      |> Map.put(:last_phase, to_string(dbc.phase_to))
      |> Map.put(:stress, stress)
      |> Map.put(:last_seen, DateTime.utc_now())
      |> Map.put(:event_count, (existing[:event_count] || 0) + 1)
      |> Map.put(:trace_id, dbc.trace_id)

    :ets.insert(table, {mat_path, updated})
  end

  defp ensure_node(table, mat_path, default_phase) do
    case :ets.lookup(table, mat_path) do
      [{^mat_path, _rec}] ->
        :ok  # already exists, do not overwrite live data with a stale default

      [] ->
        record = %{
          mat_path:    mat_path,
          node_id:     mat_path,
          phase:       to_string(default_phase),
          last_phase:  to_string(default_phase),
          stress:      0.0,
          event_count: 0,
          last_seen:   DateTime.utc_now(),
        }
        :ets.insert(table, {mat_path, record})
    end
  end

  defp build_node_record(mat_path, attrs) do
    %{
      mat_path:   mat_path,
      node_id:    attrs[:node_id] || mat_path,
      phase:      to_string(attrs[:phase] || attrs[:last_phase] || "initialized"),
      last_phase: to_string(attrs[:phase] || attrs[:last_phase] || "initialized"),
      node_tier:  to_string(attrs[:node_tier] || "agent"),
      stress:     attrs[:stress] || 0.0,
      event_count: 0,
      last_seen:   DateTime.utc_now(),
    }
  end

  defp update_causal_graph(graph, %MicroDBC{} = dbc) do
    mat_path = dbc.mat_path || dbc.node_id

    # Agent vertex
    :digraph.add_vertex(graph, mat_path, %{
      type:       :agent,
      id:         mat_path,
      last_phase: dbc.phase_to
    })

    # Hash vertex — kept in graph only (not serialized to dashboard)
    :digraph.add_vertex(graph, dbc.hash, %{type: :event, hash: dbc.hash})

    # Causal edge: agent → event
    :digraph.add_edge(graph, mat_path, dbc.hash, %{type: :emission})

    # Temporal chain: event → prev_event
    if dbc.prev_hash do
      :digraph.add_edge(graph, dbc.hash, dbc.prev_hash, %{type: :temporal})
    end
  end
end
