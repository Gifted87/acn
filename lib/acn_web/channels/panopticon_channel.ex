defmodule ACNWeb.PanopticonChannel do
  @moduledoc """
  HSG Dashboard — Real-time Panopticon Bridge.

  Bridges the PubSub telemetry stream into browser WebSocket connections.
  Any browser that joins "acn:panopticon" receives:
    - An immediate full graph snapshot on join
    - Incremental graph diffs on every MicroDBC telemetry event
    - Query results on demand
  """
  use Phoenix.Channel
  require Logger
  alias ACN.Observability.{Panopticon, Query, MicroDBC}

  @impl true
  def join("acn:panopticon", _payload, socket) do
    Phoenix.PubSub.subscribe(ACN.PubSub, MicroDBC.global_topic())
    send(self(), :push_snapshot)
    {:ok, socket}
  end

  # --- Inbound Browser Events ---

  @impl true
  def handle_in("get_snapshot", _payload, socket) do
    {:reply, {:ok, Panopticon.snapshot()}, socket}
  end

  @impl true
  def handle_in("query", %{"type" => "rejected_prompts"}, socket) do
    rows = Query.rejected_prompts()
    push(socket, "query_result", %{type: "rejected_prompts", rows: format_rows(rows)})
    {:noreply, socket}
  end

  @impl true
  def handle_in("query", %{"type" => "unauthorized_ops", "node_id" => node_id}, socket) do
    rows = Query.unauthorized_ops(node_id)
    push(socket, "query_result", %{type: "unauthorized_ops", node_id: node_id, rows: format_rows(rows)})
    {:noreply, socket}
  end

  @impl true
  def handle_in("query", %{"type" => "stress_spikes"}, socket) do
    rows = Query.stress_spike_prompts(80.0)
    push(socket, "query_result", %{type: "stress_spikes", rows: format_rows(rows)})
    {:noreply, socket}
  end

  @impl true
  def handle_in("query", %{"type" => "replay_physical", "node_id" => node_id}, socket) do
    rows = Query.replay_physical_state(node_id)
    push(socket, "query_result", %{type: "replay_physical", node_id: node_id, rows: format_rows(rows)})
    {:noreply, socket}
  end

  @impl true
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # --- Server-side info ---

  @impl true
  def handle_info(:push_snapshot, socket) do
    push(socket, "snapshot", Panopticon.snapshot())
    {:noreply, socket}
  end

  @impl true
  def handle_info({:telemetry_event, %MicroDBC{} = dbc}, socket) do
    raw_path = dbc.mat_path || dbc.node_id || ""

    # Only push diff if this is a real agent node (valid dot-notation path)
    if valid_mat_path?(raw_path) do
      # Resolve flat paths (e.g. "dependency_management") to canonical mat_paths
      # ("root.dependency_management") via the Panopticon's intent index
      mat_path =
        case :ets.lookup(:acn_hsg_id_index, raw_path) do
          [{^raw_path, full}] -> full
          [] -> raw_path
        end

      parts  = String.split(mat_path, ".")
      depth  = length(parts) - 1

      # Guard: if the resolved path is still flat (depth=0) AND it is NOT a known
      # node in the ETS node table, it means the index lookup failed to expand it.
      # Broadcasting a flat orphan ID as a "root" node would create a spurious second
      # root in the dashboard, triggering the __synth_root__ wrapper bug.
      # Skip these until the node is properly seeded via inject_intent / register_node.
      is_known_node = depth > 0 or match?([{^mat_path, _}], :ets.lookup(:acn_hsg_nodes, mat_path))

      if is_known_node do
        parent_id = if depth > 0, do: Enum.take(parts, depth) |> Enum.join("."), else: nil

        tier =
          cond do
            depth == 0 -> "root"
            depth == 1 -> "intermediate"
            true       -> "leaf"
          end

        diff = %{
          type:          "event",
          node_id:       mat_path,
          mat_path:      mat_path,
          parent_id:     parent_id,
          depth:         depth,
          node_tier:     tier,
          phase_from:    to_string(dbc.phase_from),
          phase_to:      to_string(dbc.phase_to),
          timestamp:     DateTime.to_iso8601(dbc.timestamp),
          stress:        get_in(dbc.autonomic, [:stress_level]) || 0.0,
          has_cognitive: not is_nil(dbc.cognitive),
          has_physical:  not is_nil(dbc.physical),
          has_security:  not is_nil(dbc.security),
          has_autonomic: not is_nil(dbc.autonomic)
        }

        push(socket, "graph_diff", diff)
      else
        Logger.debug("PanopticonChannel: Dropped orphan flat-path diff '#{mat_path}' (not yet registered in node table)")
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Mirrors the validation in Panopticon — ensures we never push phantom nodes
  defp valid_mat_path?(nil), do: false
  defp valid_mat_path?(""), do: false
  defp valid_mat_path?(s) when is_binary(s) do
    String.split(s, ".")
    |> Enum.all?(fn seg ->
      byte_size(seg) > 0 and
      byte_size(seg) <= 80 and
      String.match?(seg, ~r/^[a-zA-Z][a-zA-Z0-9_]*$/)
    end)
  end
  defp valid_mat_path?(_), do: false

  defp format_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row when is_tuple(row) ->
      row |> Tuple.to_list() |> Enum.map(&inspect/1)
    end)
  end
end
