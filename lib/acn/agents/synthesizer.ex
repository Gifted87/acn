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
  def handle_cast({:finalize_task, artifact_hash, path, agent_id, merge_context}, state) do
    Logger.info("Received finalization request. Artifact: #{artifact_hash}, Path: #{path}")

    # MORPHIC DISTINCTION: Query Identity from Supervisor
    # This determines whether we do Leaf finalization (atomic artifact) or Intermediate aggregation (child DBCs)
    identity = 
      case GenServer.call(ACN.Core.NodeRegistry.via_tuple(:supervisor, :supervisor), :get_identity) do
        {:ok, id} -> id
        _ -> :leaf # Default to leaf if unknown
      end

    Logger.info("Synthesizer: Node Identity = #{identity}")

    case identity do
      :leaf ->
        # LEAF NODE: Standard Artifact Finalization
        finalize_leaf_artifact(artifact_hash, path, agent_id, merge_context, state)

      :intermediate ->
        # INTERMEDIATE NODE: Aggregate Child DBCs
        finalize_intermediate_aggregation(artifact_hash, path, agent_id, merge_context, state)

      _ ->
        Logger.warning("Synthesizer: Unknown identity #{identity}. Defaulting to Leaf logic.")
        finalize_leaf_artifact(artifact_hash, path, agent_id, merge_context, state)
    end
  end

  @impl true
  def handle_cast(:request_shutdown, state) do
    Logger.info("Task Complete. Requesting Node Shutdown.")
    Router.route({:shutdown_request}, {:local, :supervisor})
    {:noreply, state}
  end

  # --- LEAF NODE FINALIZATION ---
  defp finalize_leaf_artifact(artifact_hash, path, agent_id, merge_context, state) do
    Logger.info("Synthesizer: Executing LEAF finalization (Archivist → DBC → ACMS → Parent)")

    # 1. READ: Load Artifact Content from Workspace
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
    # Retrieve validation proof from merge_context if available
    validation_proof = merge_context[:validation_proof] || %{
      validator_id: "validator_01",
      verdict: "pass",
      timestamp: DateTime.utc_now()
    }
    
    # Retrieve cost metrics from LiveWire if available
    cost_metrics = merge_context[:cost_metrics] || %{
      tokens_used: 0,
      execution_time_ms: 0
    }
    
    dbc = ACN.Core.Artifacts.DBC.new(%{
       id: UUID.uuid4(),
       artifact_hash: artifact_hash,
       fact_text: fact_text,
       vector_id: nil, # Updated below
       author_id: agent_id,
       verifier_id: "validator_01",
       validation_proof: validation_proof,
       cost_metrics: cost_metrics,
       constituents: nil, # Leaf nodes have no constituents
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

    # Record Metric
    Router.route({:record_metric, :task_complete, 1}, {:local, :live_wire})

    # Shutdown
    GenServer.cast(self(), :request_shutdown)

    {:noreply, state}
  end

  # --- INTERMEDIATE NODE AGGREGATION ---
  defp finalize_intermediate_aggregation(artifact_hash, path, agent_id, merge_context, state) do
    Logger.info("Synthesizer: Executing INTERMEDIATE aggregation (Aggregate Child DBCs)")

    # 1. COLLECT: Retrieve Child DBCs from Supervisor's Worksheet
    child_dbcs = 
      case GenServer.call(ACN.Core.NodeRegistry.via_tuple(:supervisor, :supervisor), :get_child_results) do
        {:ok, results} -> results
        _ -> []
      end

    Logger.info("Synthesizer: Retrieved #{length(child_dbcs)} child DBCs for aggregation")

    # 2. THINK: Run Aggregator Profile
    results_summary = Enum.map(child_dbcs, fn dbc ->
      %{
        "task_id" => dbc.provenance_data[:task_id] || "unknown",
        "fact" => dbc.fact_text,
        "hash" => dbc.artifact_hash
      }
    end)

    mission = merge_context[:task_description] || "Aggregate child results"

    {:ok, profile} = ACN.Core.ProfileLoader.load("synthesizer_aggregator", %{
      results: Jason.encode!(results_summary),
      mission: mission
    })
    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    aggregated_summary =
      case ACN.AI.Pipeline.run(buffer, [], config) do
         {:ok, msg, _} -> 
            try do
              Jason.decode!(msg.content)
            rescue
              _ -> %{"summary" => msg.content, "hash" => artifact_hash, "artifact" => msg.content}
            end
         _ -> %{"summary" => "Aggregation Failed", "hash" => artifact_hash}
      end

    Logger.info("Synthesizer: Aggregated Summary: #{inspect(aggregated_summary)}")

    # 3. COMMIT: Create Composite DBC
    # Extract child DBC IDs for constituents field
    constituent_ids = Enum.map(child_dbcs, fn dbc -> dbc.id end)
    
    # Aggregate cost metrics from children
    aggregated_costs = Enum.reduce(child_dbcs, %{tokens_used: 0, execution_time_ms: 0}, fn dbc, acc ->
      child_costs = dbc.cost_metrics || %{}
      %{
        tokens_used: acc.tokens_used + (child_costs[:tokens_used] || 0),
        execution_time_ms: acc.execution_time_ms + (child_costs[:execution_time_ms] || 0)
      }
    end)
    
    # Validation proof for aggregated work
    validation_proof = %{
      validator_id: "aggregator_01",
      verdict: "pass",
      aggregation_method: "llm_synthesis",
      child_count: length(child_dbcs),
      timestamp: DateTime.utc_now()
    }
    
    composite_dbc = ACN.Core.Artifacts.DBC.new(%{
       id: UUID.uuid4(),
       artifact_hash: aggregated_summary["hash"] || artifact_hash,
       fact_text: aggregated_summary["summary"],
       vector_id: nil,
       author_id: agent_id,
       verifier_id: "aggregator_01",
       validation_proof: validation_proof,
       cost_metrics: aggregated_costs,
       constituents: constituent_ids,
       timestamp: DateTime.utc_now(),
       provenance_data: %{
         path: path,
         aggregation_source: "child_dbcs",
         child_count: length(child_dbcs)
       }
    })

    # 3a. ACMS (Vector DB)
    composite_dbc =
       case MemoryClient.ingest(composite_dbc) do
         {:ok, vector_id} -> %{composite_dbc | vector_id: vector_id}
         _ ->
            Logger.warning("[ACMS_OFFLINE] Proceeding with Offline Mode.")
            composite_dbc
       end

    # 3b. Lattice Push (Parent)
    Logger.info("Executing Lattice Push to Parent: #{merge_context.parent_id}")
    lattice_args = %{
      "dbc" => composite_dbc,
      "slot_id" => merge_context.slot_id,
      "parent_id" => merge_context.parent_id
    }
    
    ACN.Tools.Lattice.UpstreamMerge.execute(lattice_args)

    # Record Metric
    Router.route({:record_metric, :task_complete, 1}, {:local, :live_wire})

    # Shutdown
    GenServer.cast(self(), :request_shutdown)

    {:noreply, state}
  end
end
