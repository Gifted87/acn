defmodule ACN.Observability.Query do
  @moduledoc """
  HSG Phase 3 — Relational Query Surface.

  Exposes "mind-bending" relational queries against the Erlang Mnesia database
  using native Erlang Match Specifications, which are O(1) across secondary indexes.
  """
  require Logger

  @doc """
  Returns all cognitive events (LLM prompting) where the result was rejected (e.g. by Judge or failure).
  """
  def rejected_prompts do
    # Tuple: { :acn_log_cognitive, id, lattice_event_id, model, temp, hash, in, out, result_accepted, ts, h, ph }
    # elem(9) is result_accepted (index 8 0-indexed, but match specs are 1-indexed so it's $9)
    match_spec = [{
      {:acn_log_cognitive, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9", :"$10", :"$11", :"$12"},
      [{:==, :"$9", false}],
      [:"$_"]
    }]
    execute_select(:acn_log_cognitive, match_spec)
  end

  @doc """
  Returns all security events for a given node where the outcome was `:denied`.
  """
  def unauthorized_ops(node_id) do
    # Tuple: { :acn_log_security, id, lattice_event_id, jwt_jti, node_id, req, granted, path, outcome, ts, h, ph }
    # node_id is $5. outcome is $9.
    match_spec = [{
      {:acn_log_security, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9", :"$10", :"$11"},
      [{:andalso, {:==, :"$3", node_id}, {:==, :"$8", :denied}}],
      [:"$_"]
    }]
    execute_select(:acn_log_security, match_spec)
  end

  @doc """
  Finds any LLM prompt that occurred while the autonomic stress level was above a threshold.
  Performs an application-level join between Autonomic and Cognitive vectors.
  """
  def stress_spike_prompts(threshold_level \\ 80.0) do
    # 1. Find all Autonomic events over threshold
    # Tuple: { :acn_log_autonomic, id, lattice_event_id, stress, rejections, livewire, ts, h, ph }
    auto_spec = [{
      {:acn_log_autonomic, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9"},
      [{:>, :"$4", threshold_level}],
      [:"$_"]
    }]
    
    high_stress_events = execute_select(:acn_log_autonomic, auto_spec)

    # 2. Extract lattice_event_ids
    _lattice_ids = Enum.map(high_stress_events, fn tuple -> elem(tuple, 3) end) # 0-indexed elem(3) = $4 ? Wait, elem(2) is lattice_event_id in Elixir.
    # Let me correct: Elixir elem(tuple, 2) is the 3rd element of the 0-indexed tuple.
    # Erlang tuple: {table, id, lattice_event_id, ...}
    # Index 0: table. Index 1: id. Index 2: lattice_event_id.
    lattice_ids_corrected = Enum.map(high_stress_events, fn tuple -> elem(tuple, 2) end)

    # 3. Retrieve matching Cognitive records
    Enum.flat_map(lattice_ids_corrected, fn l_id ->
      cog_spec = [{
        {:acn_log_cognitive, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9", :"$10", :"$11", :"$12"},
        [{:==, :"$2", l_id}],
        [:"$_"]
      }]
      execute_select(:acn_log_cognitive, cog_spec)
    end)
  end

  @doc """
  Returns all physical patch/write operations for a given node, ordered by timestamp ascending.
  This allows 1:1 "time travel" reconstruction of a directory state.
  """
  def replay_physical_state(node_id, up_to_ms \\ nil) do
    # 1. Get Lattice events for the node
    # { :acn_log_lattice, event_id, trace, span, node_id, mat_path, p_event, ts, from, to, hash, prev }
    # node_id is $5. ts is $8. event_id is $2.
    lat_spec = [{
      {:acn_log_lattice, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9", :"$10", :"$11"},
      [{:==, :"$4", node_id}],
      [:"$_"]
    }]
    
    lattice_events = execute_select(:acn_log_lattice, lat_spec)
      |> Enum.filter(fn t -> before_timestamp?(elem(t, 7), up_to_ms) end)

    l_ids = Enum.map(lattice_events, fn t -> elem(t, 1) end)

    # 2. Get associated Physical events
    Enum.flat_map(l_ids, fn l_id ->
      # { :acn_log_physical, id, lattice_event_id, file, op, diff, chk_b, chk_a, ts, h, ph }
      phys_spec = [{
        {:acn_log_physical, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9", :"$10", :"$11"},
        [{:==, :"$2", l_id}],
        [:"$_"]
      }]
      execute_select(:acn_log_physical, phys_spec)
    end)
    |> Enum.sort_by(fn t -> elem(t, 8) end, {:asc, DateTime})
  end

  # --- Private Helpers ---

  defp execute_select(table, match_spec) do
    transaction = fn -> :mnesia.select(table, match_spec) end
    case :mnesia.transaction(transaction) do
      {:atomic, results} -> results
      {:aborted, reason} ->
        Logger.error("HSG Query Failed on #{table}: #{inspect(reason)}")
        []
    end
  end

  defp before_timestamp?(nil, _), do: true
  defp before_timestamp?(_, nil), do: true
  defp before_timestamp?(timestamp, unix_limit_ms) do
    DateTime.to_unix(timestamp, :millisecond) <= unix_limit_ms
  end
end
