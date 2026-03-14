defmodule ACN.Core.AuditBuffer do
  @moduledoc """
  HSG Phase 1 — Legacy buffer shim (flat-file flush disabled).

  The AuditBuffer GenServer remains in the supervision tree for backward
  compatibility with any call-site that invokes `AuditBuffer.log/2`. However,
  the periodic flat-file flush is now a no-op.

  Physical file output is handled by `ACN.Observability.ShadowWriter` (Phase 4),
  which writes structured JSONL into the `.shadow` overlay alongside generated files.

  This module may be removed entirely once all direct callers are migrated.
  """
  use GenServer
  require Logger

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def log(node_id, message) do
    # Route to debug — ShadowWriter is now the authoritative log sink.
    Logger.debug("[AuditBuffer] node=#{node_id} #{message}")
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # No flat-file directories created; ShadowWriter owns the filesystem write path.
    Logger.debug("AuditBuffer: Started (flat-file flush disabled — HSG ShadowWriter active).")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:log, node_id, message}, state) do
    Logger.debug("[AuditBuffer] node=#{node_id} #{message}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(:periodic_flush, state) do
    # No-op. ShadowWriter handles filesystem output.
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
