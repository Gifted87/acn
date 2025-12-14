defmodule ACN.Infrastructure.StateBackup do
  use GenServer
  require Logger

  @backup_dir "priv/data/backups"

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def backup(agent_id, state) do
    GenServer.cast(__MODULE__, {:backup, agent_id, state})
  end

  def restore(agent_id) do
    GenServer.call(__MODULE__, {:restore, agent_id})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    File.mkdir_p!(@backup_dir)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:backup, agent_id, state}, state_map) do
    path = Path.join(@backup_dir, "#{agent_id}.bin")
    binary = :erlang.term_to_binary(state)
    File.write!(path, binary)
    {:noreply, state_map}
  end

  @impl true
  def handle_call({:restore, agent_id}, _from, state_map) do
    path = Path.join(@backup_dir, "#{agent_id}.bin")

    result =
      if File.exists?(path) do
         try do
           binary = File.read!(path)
           term = :erlang.binary_to_term(binary)
           {:ok, term}
         rescue
           e -> {:error, :corrupt_backup}
         end
      else
         {:error, :not_found}
      end

    {:reply, result, state_map}
  end
end
