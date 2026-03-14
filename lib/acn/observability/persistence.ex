defmodule ACN.Observability.Persistence do
  @moduledoc """
  HSG Phase 3 — The Persistent Matrix.

  A pure transactional module that maps a `MicroDBC` struct into Mnesia writes
  across all five HSG tables. Executed asynchronously by the Panopticon.
  """
  require Logger
  alias ACN.Observability.MicroDBC

  @doc """
  Takes a `MicroDBC` and commits it to Mnesia inside a single atomic transaction.
  Logs errors on failure but does not crash.
  """
  @spec persist(MicroDBC.t()) :: :ok | {:error, term()}
  def persist(%MicroDBC{} = dbc) do
    transaction = fn ->
      # 1. LATICE (The Spine)
      lattice_record = {
        :acn_log_lattice,
        dbc.event_id,
        dbc.trace_id,
        dbc.span_id,
        dbc.node_id,
        dbc.mat_path,
        dbc.parent_event_id,
        dbc.timestamp,
        dbc.phase_from,
        dbc.phase_to,
        dbc.prev_hash,
        dbc.hash
      }
      :mnesia.write(lattice_record)

      # 2. COGNITIVE (The Brain)
      if dbc.cognitive do
        cog = dbc.cognitive
        cognitive_record = {
          :acn_log_cognitive,
          :crypto.strong_rand_bytes(16) |> Base.encode16(), # unique row id
          dbc.event_id,                 # foreign key to lattice
          dbc.node_id,
          cog[:model],
          cog[:temperature],
          cog[:prompt_hash],
          cog[:token_count_in],
          cog[:token_count_out],
          cog[:result_accepted],
          dbc.timestamp,
          dbc.prev_hash,
          dbc.hash
        }
        :mnesia.write(cognitive_record)
      end

      # 3. PHYSICAL (The Hands)
      if dbc.physical do
        phys = dbc.physical
        physical_record = {
          :acn_log_physical,
          :crypto.strong_rand_bytes(16) |> Base.encode16(),
          dbc.event_id,
          dbc.node_id,
          phys[:file_path],
          phys[:operation],
          phys[:unified_diff],
          phys[:checksum_before],
          phys[:checksum_after],
          dbc.timestamp,
          dbc.prev_hash,
          dbc.hash
        }
        :mnesia.write(physical_record)
      end

      # 4. SECURITY (The Immune System)
      if dbc.security do
        sec = dbc.security
        security_record = {
          :acn_log_security,
          :crypto.strong_rand_bytes(16) |> Base.encode16(),
          dbc.event_id,
          dbc.node_id,
          sec[:jwt_jti],
          sec[:required_scopes],
          sec[:granted_scopes],
          sec[:target_path],
          sec[:outcome],
          dbc.timestamp,
          dbc.prev_hash,
          dbc.hash
        }
        :mnesia.write(security_record)
      end

      # 5. AUTONOMIC (The Nervous System)
      if dbc.autonomic do
        auto = dbc.autonomic
        autonomic_record = {
          :acn_log_autonomic,
          :crypto.strong_rand_bytes(16) |> Base.encode16(),
          dbc.event_id,
          dbc.node_id,
          auto[:stress_level],
          auto[:rejection_count],
          auto[:livewire_pid],
          dbc.timestamp,
          dbc.prev_hash,
          dbc.hash
        }
        :mnesia.write(autonomic_record)
      end

      :ok
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} ->
        :ok

      {:aborted, reason} ->
        Logger.error("HSG Persistence: Failed to commit event #{dbc.event_id} — #{inspect(reason)}")
        {:error, reason}
    end
  end
end
