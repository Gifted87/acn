defmodule ACN.Observability.Schema do
  @moduledoc """
  HSG Phase 0 — Mnesia Table Schema.

  Creates and ensures all five Vector tables exist:
    - acn_log_lattice   (The Spine)
    - acn_log_cognitive (The Brain)
    - acn_log_physical  (The Hands)
    - acn_log_security  (The Immune System)
    - acn_log_autonomic (The Nervous System)

  Each table uses `disc_copies` for persistence across restarts and carries
  a `hash` / `prev_hash` cryptographic chain column.

  This module is started as a one-shot OTP child spec in application.ex.
  It simply runs `ensure_tables/0` and exits normally. All downstream HSG
  modules may call `ensure_tables/0` themselves; the function is idempotent.
  """

  require Logger

  @tables [
    # --- LATTICE (The Spine) ---
    # Records every phase transition; the causal backbone for all vectors.
    {
      :acn_log_lattice,
      [
        attributes: [
          :event_id,          # binary() — UUID4
          :trace_id,          # binary() — root trace identifier
          :span_id,           # binary() — span within the trace
          :node_id,           # binary() — ACN node_id e.g. "auth_db"
          :materialized_path, # binary() — e.g. "root.auth.db"
          :parent_event_id,   # binary() | nil — predecessor lattice event
          :timestamp,         # DateTime.t()
          :phase_from,        # atom() e.g. :architecting
          :phase_to,          # atom() e.g. :execution
          :prev_hash,         # binary() | nil — SHA-256 of previous event
          :hash               # binary() — SHA-256 of canonical JSON of this event
        ],
        index: [:materialized_path, :trace_id, :node_id],
        disc_copies: [node()]
      ]
    },

    # --- COGNITIVE (The Brain) ---
    # Records LLM interaction metadata. Raw prompt text lives in .shadow only.
    {
      :acn_log_cognitive,
      [
        attributes: [
          :event_id,          # binary() — UUID4, primary key
          :lattice_event_id,  # binary() — FK → acn_log_lattice.event_id
          :node_id,           # binary()
          :model,             # binary() e.g. "gemini-pro"
          :temperature,       # float()
          :prompt_hash,       # binary() — SHA-256 of raw prompt (not stored here)
          :token_count_in,    # non_neg_integer()
          :token_count_out,   # non_neg_integer()
          :result_accepted,   # boolean() — false if Judge rejected
          :timestamp,         # DateTime.t()
          :prev_hash,         # binary() | nil
          :hash               # binary()
        ],
        index: [:lattice_event_id, :node_id, :result_accepted],
        disc_copies: [node()]
      ]
    },

    # --- PHYSICAL (The Hands) ---
    # Records filesystem mutations with full unified diffs.
    {
      :acn_log_physical,
      [
        attributes: [
          :event_id,          # binary() — UUID4
          :lattice_event_id,  # binary() — FK → acn_log_lattice.event_id
          :node_id,           # binary()
          :file_path,         # binary() — absolute path on disk
          :operation,         # atom() — :write | :patch | :delete | :append
          :unified_diff,      # binary() — verbatim diff text
          :checksum_before,   # binary() — SHA-256 of file before op (nil if new)
          :checksum_after,    # binary() — SHA-256 of file after op
          :timestamp,         # DateTime.t()
          :prev_hash,         # binary() | nil
          :hash               # binary()
        ],
        index: [:lattice_event_id, :node_id, :file_path],
        disc_copies: [node()]
      ]
    },

    # --- SECURITY (The Immune System) ---
    # Records every JWT mint and authorization check outcome.
    {
      :acn_log_security,
      [
        attributes: [
          :event_id,          # binary() — UUID4
          :lattice_event_id,  # binary() — FK → acn_log_lattice.event_id
          :node_id,           # binary()
          :jwt_jti,           # binary() — JWT token ID
          :required_scopes,   # [atom()] — scopes the operation needed
          :granted_scopes,    # [atom()] — scopes the token actually held
          :target_path,       # binary() — resource the token targeted
          :outcome,           # atom() — :granted | :denied | :expired
          :timestamp,         # DateTime.t()
          :prev_hash,         # binary() | nil
          :hash               # binary()
        ],
        index: [:lattice_event_id, :node_id, :outcome],
        disc_copies: [node()]
      ]
    },

    # --- AUTONOMIC (The Nervous System) ---
    # Maps LiveWire stress metrics to lattice events for cross-vector QLC joins.
    {
      :acn_log_autonomic,
      [
        attributes: [
          :event_id,          # binary() — UUID4
          :lattice_event_id,  # binary() — FK → acn_log_lattice.event_id
          :node_id,           # binary()
          :stress_level,      # float() — 0.0..100.0
          :rejection_count,   # non_neg_integer()
          :livewire_pid,      # pid() | nil
          :timestamp,         # DateTime.t()
          :prev_hash,         # binary() | nil
          :hash               # binary()
        ],
        index: [:lattice_event_id, :node_id, :stress_level],
        disc_copies: [node()]
      ]
    }
  ]

  # ---------------------------------------------------------------------------
  # OTP child_spec — one-shot Task, not a persistent GenServer
  # ---------------------------------------------------------------------------

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&ensure_tables/0]},
      restart: :transient,
      type: :worker
    }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates all HSG Mnesia tables if they do not yet exist.
  Safe to call multiple times; already-existing tables are silently skipped.
  Returns `:ok` even if some tables already existed.
  """
  @spec ensure_tables() :: :ok
  def ensure_tables do
    # Mnesia must be running before we can create tables.
    ensure_mnesia_started()

    Enum.each(@tables, fn {table_name, opts} ->
      case :mnesia.create_table(table_name, opts) do
        {:atomic, :ok} ->
          Logger.info("HSG Schema: Created Mnesia table :#{table_name}")

        {:aborted, {:already_exists, ^table_name}} ->
          Logger.debug("HSG Schema: Table :#{table_name} already exists — skipping")

        {:aborted, reason} ->
          Logger.error("HSG Schema: Failed to create table :#{table_name} — #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Returns the list of all HSG Mnesia table names.
  """
  @spec table_names() :: [atom()]
  def table_names, do: Enum.map(@tables, &elem(&1, 0))

  @doc """
  Deletes ALL HSG Mnesia tables. USE ONLY IN TESTS OR MANUAL RESET.
  """
  @spec drop_all_tables() :: :ok
  def drop_all_tables do
    Enum.each(table_names(), fn table ->
      case :mnesia.delete_table(table) do
        {:atomic, :ok} -> Logger.info("HSG Schema: Dropped table :#{table}")
        {:aborted, reason} -> Logger.warning("HSG Schema: Could not drop :#{table} — #{inspect(reason)}")
      end
    end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes ->
        :ok

      :no ->
        :mnesia.start()

      :starting ->
        Process.sleep(100)
        ensure_mnesia_started()

      :stopping ->
        Process.sleep(200)
        ensure_mnesia_started()
    end
  end
end
