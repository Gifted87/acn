defmodule ACN.Observability.TraceContext do
  @moduledoc """
  HSG Phase 0 — Trace Context Propagation.

  Injects causal identifiers into the calling process so that all downstream
  `Logger.*` calls and PubSub telemetry events carry unified tracing metadata:

    - `trace_id`  — UUID4; root-level identifier for an entire node execution.
    - `span_id`   — UUID4; identifies a sub-unit of work within a trace.
    - `mat_path`  — Materialized Path string, e.g. `"root.auth.db"`.

  The module is pure-functional — no GenServer, no ETS, no state. It writes
  exclusively to the calling process's Logger metadata and Process dictionary,
  which are already process-local and zero-contention.

  ## Process Dictionary Keys (reserved for HSG)

    - `:hsg_trace_id`    — current trace_id binary
    - `:hsg_span_stack`  — list of span_ids, head = most recent
    - `:hsg_mat_path`    — materialized path binary

  ## Usage

    In `SupervisorAgent.handle_cast({:init_node, _args}, state)`:

      TraceContext.begin_trace(node_id, parent_mat_path)
      # All Logger.info/debug/error from this point forward is tagged.

    In `Controller` before an LLM call sub-unit:

      TraceContext.new_span("llm_call")
      # ... LLM work ...
      TraceContext.pop_span()
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Begins a new root trace for the calling process.

  Computes the Materialized Path by appending `node_id` to `parent_mat_path`
  using `.` as separator (e.g. `"root"` + `"auth"` → `"root.auth"`).

  Stores `trace_id`, initial `span_id`, and `mat_path` in:
    - `Logger.metadata/1` — picked up automatically by all Logger calls
    - Process Dictionary — picked up by `Emitter.flush_and_broadcast/2`

  Returns `{trace_id, span_id, mat_path}`.
  """
  @spec begin_trace(node_id :: binary(), parent_mat_path :: binary() | nil) ::
          {trace_id :: binary(), span_id :: binary(), mat_path :: binary()}
  def begin_trace(node_id, parent_mat_path \\ nil) do
    trace_id = generate_id()
    span_id  = generate_id()
    mat_path = build_mat_path(parent_mat_path, node_id)

    # Write to Process Dictionary (harvested by Emitter)
    Process.put(:hsg_trace_id,   trace_id)
    Process.put(:hsg_span_stack, [span_id])
    Process.put(:hsg_mat_path,   mat_path)

    # Annotate Logger metadata — inherited by all Logger calls in this process
    :logger.set_process_metadata(%{
      hsg_trace_id: trace_id,
      hsg_span_id:  span_id,
      hsg_mat_path: mat_path
    })

    Logger.debug("TraceContext.begin_trace — node=#{node_id} mat_path=#{mat_path} trace=#{trace_id}")

    {trace_id, span_id, mat_path}
  end

  @doc """
  Opens a new child span within the current trace.

  Pushes a fresh `span_id` onto the `:hsg_span_stack` in the Process Dictionary
  and updates `Logger.metadata` so subsequent log lines carry the child span ID.
  The root `trace_id` is never changed.

  Returns the new `span_id`.
  """
  @spec new_span(label :: binary()) :: span_id :: binary()
  def new_span(label) do
    span_id = generate_id()
    stack   = Process.get(:hsg_span_stack, [])

    Process.put(:hsg_span_stack, [span_id | stack])
    :logger.set_process_metadata(%{hsg_span_id: span_id})

    Logger.debug("TraceContext.new_span — label=#{label} span=#{span_id}")

    span_id
  end

  @doc """
  Closes the current span and restores the parent span.

  If no parent span exists (we are at the root), the root span is retained.
  Returns the span_id that was popped, or `nil` if the stack was already empty.
  """
  @spec pop_span() :: span_id :: binary() | nil
  def pop_span do
    case Process.get(:hsg_span_stack, []) do
      [] ->
        nil

      [only_one] ->
        # Keep root span, do not go below it
        :logger.set_process_metadata(%{hsg_span_id: only_one})
        only_one

      [current | [parent | _rest] = remaining] ->
        Process.put(:hsg_span_stack, remaining)
        :logger.set_process_metadata(%{hsg_span_id: parent})
        current
    end
  end

  @doc """
  Returns current trace metadata from the Process Dictionary.

  Returns a map with `:trace_id`, `:span_id`, `:mat_path`.
  Any field that hasn't been set yet will be `nil`.
  """
  @spec current() :: %{trace_id: binary() | nil, span_id: binary() | nil, mat_path: binary() | nil}
  def current do
    span_id =
      case Process.get(:hsg_span_stack, []) do
        [head | _] -> head
        [] -> nil
      end

    %{
      trace_id: Process.get(:hsg_trace_id),
      span_id:  span_id,
      mat_path: Process.get(:hsg_mat_path)
    }
  end

  @doc """
  Propagates trace context from a parent process payload into the current process.

  Used when a child agent is spawned and needs to inherit the parent's materialized
  path prefix so it can compute its own path correctly.

  The child calls: `TraceContext.begin_trace(my_node_id, parent_mat_path)`

  This helper simply extracts the `mat_path` from a context map/struct so
  callers don't need to pattern-match manually.
  """
  @spec extract_parent_mat_path(context :: map()) :: binary() | nil
  def extract_parent_mat_path(context) when is_map(context) do
    context[:mat_path] || context["mat_path"] ||
      context[:hsg_mat_path] || context["hsg_mat_path"] ||
      context[:materialized_path] || context["materialized_path"]
  end

  def extract_parent_mat_path(_), do: nil

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  @spec build_mat_path(parent :: binary() | nil, node_id :: binary()) :: binary()
  defp build_mat_path(nil, node_id),    do: sanitize(node_id)
  defp build_mat_path("", node_id),     do: sanitize(node_id)
  defp build_mat_path(parent, node_id), do: "#{sanitize(parent)}.#{sanitize(node_id)}"

  # Strip characters that are not safe in a materialized path segment.
  # Only alphanumerics, underscores, and hyphens are permitted per segment.
  defp sanitize(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-\.]/, "_")
    |> String.trim(".")
  end

  defp sanitize(other), do: sanitize(to_string(other))

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16()
end
