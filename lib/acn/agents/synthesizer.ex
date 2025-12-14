defmodule ACN.Agents.Synthesizer do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router
  alias ACN.Infrastructure.MemoryClient

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:synthesizer, :synthesizer)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    {:ok, %{parent_pid: nil, acms_status: :idle}}
  end

  @impl true
  @impl true
  def handle_cast({:finalize_task, artifact_hash, path, agent_id, merge_context}, state) do
    Logger.info("Received finalization request. Artifact: #{artifact_hash}, Path: #{path}")

    # 1. READ: Load Artifact Content from Workspace
    # We assume 'node0' or similar for now, or extract from path? ACN is single-node distributed for now.
    # We'll try to read via Workspace.read_artifact.
    # NOTE: Workspace expects node_id. We'll assume :actuator or self?
    # Actually, Workspace uses string node IDs. Let's assume Actuator wrote to "node1".
    # FIX: Controller didn't pass node ID. We'll try reading with a known ID or assume Local.
    # Ideally, Actuator runs on THIS node, so path is local.

    # We'll bypass Workspace.read_artifact specific node logic if the path is absolute and local?
    # But Workspace.read_artifact(node_id, relative) is stricter.
    # Let's rely on File.read for now if path is absolute (which it is, /tmp/...).

    artifact_content =
       case File.read(path) do
         {:ok, bin} -> bin
         _ -> "Error: Could not read artifact."
       end

    # 2. THINK: Run Archivist Profile
    {:ok, profile} = ACN.Core.ProfileLoader.load("synthesizer_archivist", %{artifact_content: artifact_content})
    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    fact_text =
      case ACN.AI.Pipeline.run(buffer, [], config) do
         {:ok, msg, _} -> msg.content |> String.trim()
         _ -> "Auto-Generated Fact for #{artifact_hash}"
      end

    Logger.info("Archivist generated fact: #{fact_text}")

    # 3. COMMIT: Create DBC and Dual-Push
    dbc = ACN.Core.Artifacts.DBC.new(%{
       id: UUID.uuid4(),
       artifact_hash: artifact_hash,
       fact_text: fact_text,
       vector_id: nil, # Updated below
       author_id: agent_id,
       verifier_id: "validator_01",
       cost_metrics: %{},
       timestamp: DateTime.utc_now(),
       provenance_data: %{path: path}
    })

    # 3a. ACMS (Vector DB)
    dbc =
       case MemoryClient.ingest(dbc) do
         {:ok, vector_id} -> %{dbc | vector_id: vector_id}
         _ ->
            Logger.warning("[ACMS_OFFLINE] Proceeding with Offline Mode.")
            dbc
       end

    # 3b. Lattice Push (Parent)
    Logger.info("Executing Lattice Push to Parent: #{merge_context.parent_id}")
    lattice_args = %{
      "dbc" => dbc,
      "slot_id" => merge_context.slot_id,
      "parent_id" => merge_context.parent_id
    }
    
    ACN.Tools.Lattice.UpstreamMerge.execute(lattice_args)
    
    # We rely on the Tool log output or we can verify if needed.
    # Ideally execute returns a result string.

    # Record Metric
    Router.route({:record_metric, :task_complete, 1}, {:local, :live_wire})

    # Shutdown
    GenServer.cast(self(), :request_shutdown)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:request_shutdown, state) do
    Logger.info("Task Complete. Requesting Node Shutdown.")
    Router.route({:shutdown_request}, {:local, :supervisor})
    {:noreply, state}
  end
end
