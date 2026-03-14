defmodule ACN.Infrastructure.StateBackup do
  use GenServer
  require Logger

  @backup_dir "priv/data/backups"

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def backup(agent_id, state, node_id \\ "global") do
    GenServer.cast(__MODULE__, {:backup, agent_id, state, node_id})
  end

  def restore(agent_id, node_id \\ "global") do
    GenServer.call(__MODULE__, {:restore, agent_id, node_id})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    File.mkdir_p!(@backup_dir)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:backup, agent_id, state, node_id}, state_map) do
    filename = "#{node_id}_#{agent_id}.bin"
    path = Path.join(@backup_dir, filename)
    binary = :erlang.term_to_binary(state)
    File.write!(path, binary)
    {:noreply, state_map}
  end

  @impl true
  def handle_call({:restore, agent_id, node_id}, _from, state_map) do
    filename = "#{node_id}_#{agent_id}.bin"
    path = Path.join(@backup_dir, filename)

    result =
      if File.exists?(path) do
         try do
           binary = File.read!(path)
           term = :erlang.binary_to_term(binary)
           {:ok, term}
         rescue
           _e -> {:error, :corrupt_backup}
         end
      else
         {:error, :not_found}
      end

    {:reply, result, state_map}
  end
end
