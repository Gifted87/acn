defmodule ACN.Observability.MicroDBC do
  @moduledoc """
  HSG Phase 0 — Universal Telemetry Payload (Micro Design-By-Contract).

  A `MicroDBC` struct is the canonical unit of observability in the HSG system.
  It is built at every phase-transition point by `ACN.Observability.Emitter`,
  carrying a complete snapshot of one agent's vector state at that moment.

  ## Cryptographic Hash Chain

  Each event hashes itself (SHA-256 over canonical JSON) and stores the hash
  of its immediate predecessor (`prev_hash`). This creates a per-node immutable
  chain of evidence. To verify chain integrity, see
  `ACN.Observability.ChainVerifier`.

  ## The 5 Vectors

  Each vector sub-map is optional (`nil` if not populated).

  | Field       | Vector   | Populated By       |
  |-------------|----------|--------------------|
  | `:cognitive`| Brain    | `controller.ex`    |
  | `:physical` | Hands    | `actuator.ex`      |
  | `:security` | Immune   | `token_authority`  |
  | `:autonomic`| Nervous  | `live_wire.ex`     |
  | (struct)    | Spine    | `emitter.ex`       |

  The Lattice (Spine) vector is the struct itself — every MicroDBC carries the
  trace/span/mat_path causal context, so there is no separate `:lattice` sub-map.

  ## Process Dictionary Keys Harvested by `build/1`

  | Key                  | Type     |
  |----------------------|----------|
  | `:hsg_trace_id`      | binary() |
  | `:hsg_span_stack`    | [binary()]|
  | `:hsg_mat_path`      | binary() |
  | `:hsg_token_in`      | integer()|
  | `:hsg_token_out`     | integer()|
  | `:hsg_prompt_hash`   | binary() |
  | `:hsg_model`         | binary() |
  | `:hsg_temperature`   | float()  |
  | `:hsg_result_accepted`| boolean()|
  | `:hsg_physical`      | map()    |
  | `:hsg_security`      | map()    |
  | `:hsg_stress_level`  | float()  |
  | `:hsg_rejection_count`| integer()|
  | `:hsg_last_hash`     | binary() | (updated after build)
  """

  alias __MODULE__

  defstruct [
    # Identity & Causality (Spine / Lattice)
    :event_id,          # binary() — UUID4
    :trace_id,          # binary() — root trace identifier
    :span_id,           # binary() — sub-span within trace
    :node_id,           # binary() — ACN node_id
    :mat_path,          # binary() — e.g. "root.auth.db"
    :parent_event_id,   # binary() | nil — previous event in THIS node's chain

    # Phase Transition
    :phase_from,        # atom()
    :phase_to,          # atom()
    :timestamp,         # DateTime.t()

    # 5 Vectors (all optional)
    :cognitive,         # map() | nil
    :physical,          # map() | nil
    :security,          # map() | nil
    :autonomic,         # map() | nil

    # Cryptographic chain
    :prev_hash,         # binary() | nil — hash of predecessor event
    :hash               # binary() — SHA-256 of canonical JSON of this struct
  ]

  @type t :: %MicroDBC{}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds a `MicroDBC` from the calling process's state.

  Harvests all `:hsg_*` Process Dictionary keys, assembles the struct,
  computes `prev_hash` from `:hsg_last_hash`, computes the event `hash`,
  and stores the new hash back as `:hsg_last_hash` for the next event.

  ## Options (override auto-harvested values when needed)

    - `:node_id`      — required
    - `:phase_from`   — required
    - `:phase_to`     — required
    - `:parent_event_id` — optional

  Returns `%MicroDBC{}`.
  """
  @spec build(opts :: keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) do
    node_id    = Keyword.fetch!(opts, :node_id)
    phase_from = Keyword.fetch!(opts, :phase_from)
    phase_to   = Keyword.fetch!(opts, :phase_to)
    parent_event_id = Keyword.get(opts, :parent_event_id)

    # --- Harvest trace context from Process Dictionary ---
    trace_id = Process.get(:hsg_trace_id)
    span_id  = hd_or_nil(Process.get(:hsg_span_stack, []))
    mat_path = Process.get(:hsg_mat_path) || node_id

    # --- Harvest vector payloads ---
    cognitive = build_cognitive_vector()
    physical  = Process.get(:hsg_physical)
    security  = Process.get(:hsg_security)
    autonomic = build_autonomic_vector()

    # --- Chain linkage ---
    prev_hash = Process.get(:hsg_last_hash)

    event_id  = UUID.uuid4()
    timestamp = DateTime.utc_now()

    # Build pre-hash struct (hash field is nil until computed)
    pre_struct = %MicroDBC{
      event_id:        event_id,
      trace_id:        trace_id,
      span_id:         span_id,
      node_id:         node_id,
      mat_path:        mat_path,
      parent_event_id: parent_event_id,
      phase_from:      phase_from,
      phase_to:        phase_to,
      timestamp:       timestamp,
      cognitive:       cognitive,
      physical:        physical,
      security:        security,
      autonomic:       autonomic,
      prev_hash:       prev_hash,
      hash:            nil
    }

    # Compute hash over canonical JSON of struct (excluding :hash itself)
    computed_hash = compute_hash(pre_struct)

    final_struct = %{pre_struct | hash: computed_hash}

    # Store the new hash so the NEXT event can link to it
    Process.put(:hsg_last_hash, computed_hash)

    {:ok, final_struct}
  rescue
    e ->
      {:error, {:build_failed, Exception.message(e)}}
  end

  @doc """
  Computes the PubSub topic for a given materialized path.

  ## Example

      iex> MicroDBC.to_pubsub_topic("root.auth.db")
      "acn:telemetry:root.auth.db"
  """
  @spec to_pubsub_topic(mat_path :: binary()) :: binary()
  def to_pubsub_topic(mat_path), do: "acn:telemetry:#{mat_path}"

  @doc """
  Returns the global wildcard topic that the Panopticon subscribes to.
  All events are also broadcast on this topic.
  """
  @spec global_topic() :: binary()
  def global_topic, do: "acn:telemetry:all"

  @doc """
  Recomputes the hash for a given `MicroDBC` struct (excluding the `:hash` field).

  Used by `ACN.Observability.ChainVerifier` to validate stored events.
  """
  @spec compute_hash(t()) :: binary()
  def compute_hash(%MicroDBC{} = dbc) do
    canonical =
      dbc
      |> Map.from_struct()
      |> Map.drop([:hash])
      |> encode_for_hash()

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Converts a `MicroDBC` to a JSON-safe map suitable for PubSub broadcast,
  Phoenix dashboard serialisation, or Mnesia row construction.
  """
  @spec to_map(t()) :: map()
  def to_map(%MicroDBC{} = dbc) do
    dbc
    |> Map.from_struct()
    |> Map.update!(:timestamp, &DateTime.to_iso8601/1)
    |> Map.update!(:phase_from, &to_string/1)
    |> Map.update!(:phase_to, &to_string/1)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers — Vector builders
  # ---------------------------------------------------------------------------

  defp build_cognitive_vector do
    token_in    = Process.get(:hsg_token_in)
    token_out   = Process.get(:hsg_token_out)
    model       = Process.get(:hsg_model)
    temp        = Process.get(:hsg_temperature)
    phash       = Process.get(:hsg_prompt_hash)
    accepted    = Process.get(:hsg_result_accepted)
    raw_prompt  = Process.get(:hsg_raw_prompt)
    raw_response = Process.get(:hsg_raw_response)

    # Only build a cognitive vector if at least one field is populated
    if Enum.any?([token_in, token_out, model, temp, phash, accepted, raw_prompt], &(not is_nil(&1))) do
      %{
        model:           model,
        temperature:     temp,
        prompt_hash:     phash,
        token_count_in:  token_in  || 0,
        token_count_out: token_out || 0,
        result_accepted: accepted,
        # RAM-only fields — read by ShadowWriter, stripped before Mnesia commit
        raw_prompt:      raw_prompt,
        raw_response:    raw_response
      }
    else
      nil
    end
  end

  defp build_autonomic_vector do
    stress     = Process.get(:hsg_stress_level)
    rejections = Process.get(:hsg_rejection_count)

    if Enum.any?([stress, rejections], &(not is_nil(&1))) do
      %{
        stress_level:     stress     || 0.0,
        rejection_count:  rejections || 0,
        livewire_pid:     self()
      }
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers — Hashing
  # ---------------------------------------------------------------------------

  # Converts map to a deterministic JSON binary for hashing.
  # Elixir maps have consistent ordering when using Jason with sorted keys.
  defp encode_for_hash(map) do
    map
    |> deep_stringify()
    |> Jason.encode!(pretty: false)
  rescue
    _ ->
      # Fallback: inspect if Jason fails (should not happen with normalised data)
      inspect(map)
  end

  # Recursively converts atoms/pids/etc. to strings so Jason can encode cleanly.
  defp deep_stringify(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), deep_stringify(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp deep_stringify(value) when is_list(value), do: Enum.map(value, &deep_stringify/1)
  defp deep_stringify(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: to_string(value)
  defp deep_stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp deep_stringify(value) when is_pid(value), do: inspect(value)
  defp deep_stringify(value) when is_reference(value), do: inspect(value)
  defp deep_stringify(value), do: value

  defp hd_or_nil([head | _]), do: head
  defp hd_or_nil(_), do: nil
end
