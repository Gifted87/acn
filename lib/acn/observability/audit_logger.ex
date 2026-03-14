defmodule ACN.Observability.AuditLogger do
  @moduledoc """
  HSG Phase 1 — Backward-Compatible Audit Shim.

  This module is now a thin compatibility shim over the HSG Emission Layer.
  All existing call-sites continue to work without modification.

  Events are downgraded to `Logger.debug` (not `Logger.info`) because the
  authoritative observability stores are now Mnesia (via Panopticon) and the
  `.shadow` workspace overlay. The `[AUDIT]` prefix is removed to reduce noise.

  Migration path: Once all agents are migrated to call `Emitter` directly,
  this module can be deleted.
  """
  require Logger

  def log_lineage(parent_node, child_node, task) do
    Logger.debug(
      "[HSG:lineage] parent=#{parent_node} child=#{child_node} task=#{String.slice(task, 0, 80)}"
    )
  end

  def log_bot_io(node_id, bot_name, phase, inputs, _outputs) do
    token_count = count_tokens(inputs)

    # Push the cognitive data into the Process Dict for the next Emitter flush.
    # This bridges old-style log_bot_io calls into the HSG stream.
    ACN.Observability.Emitter.push_cognitive(%{
      model:           to_string(bot_name),
      token_count_in:  token_count,
      token_count_out: 0
    })

    Logger.debug("[HSG:bot_io] node=#{node_id} bot=#{bot_name} phase=#{phase} tokens≈#{token_count}")
  end

  def log_event(node_id, event_type, details) do
    Logger.debug("[HSG:event] node=#{node_id} type=#{event_type} details=#{inspect(details, limit: 80)}")
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp count_tokens(input) when is_binary(input), do: byte_size(input) |> div(4)
  defp count_tokens(_), do: 0
end
