defmodule ACN.Observability.Emitter do
  @moduledoc """
  HSG Phase 1 — Zero-Contention Emission Engine.

  This module is the single point of emission for the HSG telemetry stream.
  It is a pure-function module — no GenServer, no ETS, no state of its own.
  All data it works with lives in the calling process's Process Dictionary.

  ## Calling Convention

  Each agent calls `flush_and_broadcast/3` at a phase-transition boundary:

      # In controller.ex, before {:noreply, %{state | phase: :execution}}:
      Emitter.flush_and_broadcast(:architecting, :execution, state.node_id)

  ## What Happens on Each Call

  1. **Gather** — Reads all `:hsg_*` Process Dictionary keys.
  2. **Build** — Constructs a `MicroDBC` with a SHA-256 hash chain.
  3. **Clear** — Resets mutable `:hsg_*` keys (keeps trace/span/mat_path stable).
  4. **Broadcast** — Fires TWO PubSub broadcasts:
       - Targeted: `"acn:telemetry:<mat_path>"`   (for subscribed dashboards)
       - Global:   `"acn:telemetry:all"`           (for the Panopticon)
  5. **Return** — Returns the built `MicroDBC` for optional inspection.

  ## Process Dictionary Convention

  Keys are defined in `ACN.Observability.MicroDBC` documentation.
  This module **clears** the mutable vector keys after every flush so they
  do not leak into the next phase's event.
  """

  require Logger
  alias ACN.Observability.MicroDBC
  alias ACN.Observability.TraceContext

  # Keys cleared after each flush (vector data, not trace context)
  @vector_keys [
    :hsg_token_in,
    :hsg_token_out,
    :hsg_prompt_hash,
    :hsg_model,
    :hsg_temperature,
    :hsg_result_accepted,
    :hsg_raw_prompt,
    :hsg_raw_response,
    :hsg_physical,
    :hsg_security,
    :hsg_stress_level,
    :hsg_rejection_count
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Core emission function. Harvests the Process Dictionary, builds a `MicroDBC`,
  broadcasts it over PubSub, and returns the built struct.

  Opts:
    - `:parent_event_id` — optional, links to a parent lattice event
  """
  @spec flush_and_broadcast(phase_from :: atom(), phase_to :: atom(), node_id :: binary(), opts :: keyword()) ::
          {:ok, MicroDBC.t()} | {:error, term()}
  def flush_and_broadcast(phase_from, phase_to, node_id, opts \\ []) do
    # Ensure trace context is present (defensive: begin_trace may not have fired if the
    # agent is very old or was started before HSG was deployed)
    ensure_trace_context(node_id)

    case MicroDBC.build(
           Keyword.merge(opts, node_id: node_id, phase_from: phase_from, phase_to: phase_to)
         ) do
      {:ok, micro_dbc} ->
        # Broadcast on the targeted topic (per-path subscribers)
        targeted_topic = MicroDBC.to_pubsub_topic(micro_dbc.mat_path)
        Phoenix.PubSub.broadcast(ACN.PubSub, targeted_topic, {:telemetry_event, micro_dbc})

        # Broadcast on the global wildcard topic (Panopticon)
        Phoenix.PubSub.broadcast(ACN.PubSub, MicroDBC.global_topic(), {:telemetry_event, micro_dbc})

        Logger.debug(
          "HSG Emitter: Flushed #{phase_from}→#{phase_to} for #{node_id} " <>
            "[trace=#{shorten(micro_dbc.trace_id)} hash=#{shorten(micro_dbc.hash)}]"
        )

        # Clear mutable vector keys so the NEXT phase starts clean
        clear_vector_keys()

        {:ok, micro_dbc}

      error ->
        Logger.error("HSG Emitter: Failed to build MicroDBC — #{inspect(error)}")
        error
    end
  end

  @doc """
  Convenience: push a token count snapshot from a Controller LLM call into
  the Process Dictionary. Call this immediately after receiving the LLM response.
  """
  @spec push_cognitive(map()) :: :ok
  def push_cognitive(attrs) do
    if token_in = attrs[:token_count_in] || attrs[:tokens_in],
      do: Process.put(:hsg_token_in, token_in)

    if token_out = attrs[:token_count_out] || attrs[:tokens_out],
      do: Process.put(:hsg_token_out, token_out)

    if model = attrs[:model],
      do: Process.put(:hsg_model, to_string(model))

    if temp = attrs[:temperature],
      do: Process.put(:hsg_temperature, temp)

    if prompt = attrs[:prompt] || attrs[:raw_prompt] do
      hash = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
      Process.put(:hsg_prompt_hash, hash)
      # Store raw text for .shadow/cognitive.jsonl (never written to Mnesia)
      Process.put(:hsg_raw_prompt, prompt)
    end

    if response = attrs[:raw_response],
      do: Process.put(:hsg_raw_response, response)

    if accepted = attrs[:result_accepted],
      do: Process.put(:hsg_result_accepted, accepted)

    :ok
  end

  @doc """
  Convenience: push a physical vector payload into the Process Dictionary.
  Call this from the Actuator after a filesystem write/patch/append.
  """
  @spec push_physical(map()) :: :ok
  def push_physical(attrs) do
    Process.put(:hsg_physical, %{
      file_path:        attrs[:file_path] || attrs[:path],
      operation:        attrs[:operation] || :write,
      unified_diff:     attrs[:unified_diff] || attrs[:diff],
      checksum_before:  attrs[:checksum_before],
      checksum_after:   attrs[:checksum_after]
    })
    :ok
  end

  @doc """
  Convenience: push security vector data.
  Call from TokenAuthority or the Actuator gatekeeper on every verification.
  """
  @spec push_security(map()) :: :ok
  def push_security(attrs) do
    Process.put(:hsg_security, %{
      jwt_jti:         attrs[:jwt_jti],
      required_scopes: List.wrap(attrs[:required_scopes] || attrs[:required_scope]),
      granted_scopes:  List.wrap(attrs[:granted_scopes]  || attrs[:granted_scope]),
      target_path:     attrs[:target_path] || attrs[:resource],
      outcome:         attrs[:outcome] || :granted
    })
    :ok
  end

  @doc """
  Convenience: push an autonomic (stress) vector snapshot.
  Call from LiveWire on every pain_signal cast.
  """
  @spec push_autonomic(stress_level :: float(), rejection_count :: non_neg_integer()) :: :ok
  def push_autonomic(stress_level, rejection_count) do
    Process.put(:hsg_stress_level, stress_level)
    Process.put(:hsg_rejection_count, rejection_count)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp ensure_trace_context(node_id) do
    if is_nil(Process.get(:hsg_trace_id)) do
      # Defensively begin a minimal trace so MicroDBC.build/1 doesn't get nils
      TraceContext.begin_trace(node_id, nil)
    end
  end

  defp clear_vector_keys do
    Enum.each(@vector_keys, &Process.delete/1)
  end

  defp shorten(nil), do: "nil"
  defp shorten(str) when byte_size(str) <= 12, do: str
  defp shorten(str), do: String.slice(str, 0, 12) <> "…"
end
