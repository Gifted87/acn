defmodule ACNWeb.PanopticonChannel do
  @moduledoc """
  HSG Dashboard — Real-time Panopticon Bridge.

  Bridges the PubSub telemetry stream into browser WebSocket connections.
  Any browser that joins "acn:panopticon" receives:
    - An immediate full graph snapshot on join
    - Incremental graph diffs on every MicroDBC telemetry event
    - Query results on demand (rejected_prompts, stress_spikes, etc.)
  """
  use Phoenix.Channel
  require Logger
  alias ACN.Observability.{Panopticon, Query, MicroDBC}

  @impl true
  def join("acn:panopticon", _payload, socket) do
    # Subscribe to live HSG telemetry stream
    Phoenix.PubSub.subscribe(ACN.PubSub, MicroDBC.global_topic())

    # Send the full current graph snapshot immediately so the browser
    # has something to render before the first live event arrives.
    send(self(), :push_snapshot)

    {:ok, socket}
  end

  # --- Inbound Browser Events ---

  @impl true
  def handle_in("get_snapshot", _payload, socket) do
    {:reply, {:ok, build_snapshot()}, socket}
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

  # --- Server-side info (PubSub + init) ---

  @impl true
  def handle_info(:push_snapshot, socket) do
    push(socket, "snapshot", build_snapshot())
    {:noreply, socket}
  end

  @impl true
  def handle_info({:telemetry_event, %MicroDBC{} = dbc}, socket) do
    # Build a lightweight diff payload — just enough for the browser
    # to merge into its local graph state without a full re-download.
    diff = %{
      type:       "event",
      node_id:    dbc.node_id,
      event_hash: dbc.hash,
      prev_hash:  dbc.prev_hash,
      mat_path:   dbc.mat_path,
      phase_from: to_string(dbc.phase_from),
      phase_to:   to_string(dbc.phase_to),
      timestamp:  DateTime.to_iso8601(dbc.timestamp),
      stress:     get_in(dbc.autonomic, [:stress_level]),
      has_cognitive: not is_nil(dbc.cognitive),
      has_physical:  not is_nil(dbc.physical),
      has_security:  not is_nil(dbc.security),
      has_autonomic: not is_nil(dbc.autonomic)
    }

    push(socket, "graph_diff", diff)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private Helpers ---

  defp build_snapshot do
    %{vertices: verts, edges: edges} = Panopticon.snapshot()

    serialized_verts =
      Enum.map(verts, fn {id, label} ->
        %{
          id:         to_string(id),
          type:       to_string(label[:type] || "unknown"),
          last_phase: to_string(label[:last_phase] || ""),
          stress:     label[:stress],
          mat_path:   to_string(label[:id] || id)
        }
      end)

    serialized_edges =
      Enum.map(edges, fn %{id: eid, from: f, to: t, label: lab} ->
        %{
          id:   to_string(eid),
          from: to_string(f),
          to:   to_string(t),
          type: to_string(lab[:type] || "edge")
        }
      end)

    %{vertices: serialized_verts, edges: serialized_edges}
  end

  defp format_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row when is_tuple(row) ->
      row |> Tuple.to_list() |> Enum.map(&inspect/1)
    end)
  end
end
