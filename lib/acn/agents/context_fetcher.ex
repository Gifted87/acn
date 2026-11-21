defmodule ACN.Agents.ContextFetcher do
  use GenServer
  require Logger
  alias ACN.Infrastructure.Lattice.{RPC, DeepContext}
  alias ACN.Infrastructure.MemoryClient

  defmodule State do
    defstruct [:supervisor_pid, :task_desc, :path, :lineage]
  end

  # --- Public API ---

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def hydrate(pid, task_desc, path, lineage, spec_data \\ %{}) do
    GenServer.cast(pid, {:hydrate, task_desc, path, lineage, spec_data})
  end

  # --- Server Callbacks ---

  @impl true
  def init(args) do
    # args should include supervisor_pid
    {:ok, %State{supervisor_pid: args[:supervisor_pid]}}
  end

  @impl true
  def handle_cast({:hydrate, task_desc, path, lineage, spec_data}, state) do
    Logger.info("ContextFetcher Agent: Starting Parallel Pillar Hydration...")
    
    # CRITICAL VALIDATION: Check path before expensive hydration
    is_path_valid = is_binary(path) && String.length(path) > 0 && 
                    path != "root" && 
                    (String.starts_with?(path, "/") || String.starts_with?(path, "~"))
    
    if !is_path_valid do
       Logger.error("ContextFetcher: Invalid path detected: #{inspect(path)}. Path must be absolute and not 'root'.")
       # Send error back to supervisor to trigger retry
       GenServer.cast(state.supervisor_pid, {:hydration_failed, :invalid_path, path})
       {:noreply, state}
    else
      # 1. Start Parallel Fetch Threads
      task_rules = Task.async(fn -> fetch_rules(lineage) end)
      task_worksheets = Task.async(fn -> fetch_worksheets(lineage) end)
      task_acms = Task.async(fn -> fetch_acms(task_desc) end)
      task_blueprint = Task.async(fn -> fetch_blueprint(lineage.parent, lineage.parent_id) end)

      # 2. Await Results
      rules_result = Task.await(task_rules, 30_000)
      worksheets_result = Task.await(task_worksheets, 30_000)
      blueprint_result = Task.await(task_blueprint, 30_000)
      acms_result = Task.await(task_acms, 300_000) # Increased for Rate Limiting queue

      # 3. Assemble DeepContext
      deep_context = %DeepContext{
        blueprint: blueprint_result,
        rules: rules_result,
        worksheets: worksheets_result,
        acms_results: acms_result,
        task: task_desc,
        path: path,
        parent_node_id: lineage[:parent_id] || "root",
        # SPECIFICATION FIDELITY: Include specification fields
        original_specification: spec_data[:original_specification],
        specification_depth: spec_data[:specification_depth],
        specification_metadata: spec_data[:specification_metadata]
      }

      Logger.info("ContextFetcher Agent: Hydration Complete. Notifying Supervisor.")
      
      # 4. Notify Supervisor
      GenServer.cast(state.supervisor_pid, {:hydration_ready, deep_context})

      {:noreply, state}
    end
  end

  # --- Private Helpers (Pillar Logic) ---

  defp fetch_rules(lineage) do
    p_rules = if lineage.parent, do: rpc_call(lineage.parent, :get_rules, [], [id: lineage.parent_id, silent: true]), else: []
    gp_rules = if lineage.grandparent, do: rpc_call(lineage.grandparent, :get_rules, [], [id: lineage.grandparent_id, silent: true]), else: []
    ggp_rules = if lineage.great_grandparent, do: rpc_call(lineage.great_grandparent, :get_rules, [], [id: lineage.great_grandparent_id, silent: true]), else: []
    
    %DeepContext.Rules{
      master: ACN.Core.Governance.MasterRules.get_rules(),
      ancestral: List.wrap(p_rules) ++ List.wrap(gp_rules) ++ List.wrap(ggp_rules),
      local: []
    }
  end

  defp fetch_worksheets(lineage) do
    %{
      parent: if(lineage.parent, do: rpc_call(lineage.parent, :get_worksheet, %{}, [id: lineage.parent_id, silent: true]), else: %{}),
      grandparent: if(lineage.grandparent, do: rpc_call(lineage.grandparent, :get_worksheet, %{}, [id: lineage.grandparent_id, silent: true]), else: %{}),
      great_grandparent: if(lineage.great_grandparent, do: rpc_call(lineage.great_grandparent, :get_worksheet, %{}, [id: lineage.great_grandparent_id, silent: true]), else: %{})
    }
  end

  defp fetch_blueprint(nil, _), do: "No ancestral blueprint available (Root)."
  defp fetch_blueprint(parent_pid, parent_id) do
    rpc_call(parent_pid, :get_blueprint, "No blueprint obtained from parent.", [id: parent_id, silent: true])
  end

  defp fetch_acms(query) do
    case MemoryClient.query(query, 5) do
      {:ok, results} -> deduplicate_acms_results(results)
      _ -> []
    end
  end

  defp deduplicate_acms_results(results) when is_list(results) do
    {unique, _seen} =
      Enum.reduce(results, {[], MapSet.new()}, fn result, {kept, seen} ->
        case acms_result_identity(result) do
          nil -> {kept ++ [result], seen}
          identity ->
            if MapSet.member?(seen, identity) do
              {kept, seen}
            else
              {kept ++ [result], MapSet.put(seen, identity)}
            end
        end
      end)

    if length(unique) < length(results) do
      Logger.info("ContextFetcher: Deduplicated #{length(results) - length(unique)} ACMS results by artifact identity.")
    end

    unique
  end

  defp deduplicate_acms_results(results), do: results

  defp acms_result_identity(result) when is_map(result) do
    artifact_hash = Map.get(result, :artifact_hash) || Map.get(result, "artifact_hash")
    id = Map.get(result, :id) || Map.get(result, "id")

    cond do
      is_binary(artifact_hash) and artifact_hash not in ["", "placeholder", "unknown"] ->
        {:artifact_hash, artifact_hash}

      is_binary(id) and id != "" ->
        {:id, id}

      true ->
        nil
    end
  end

  defp acms_result_identity(_), do: nil

  defp rpc_call(pid, call, default, opts \\ []) do
    case RPC.fast_call(pid, call, 5000, opts) do
      {:ok, {:ok, result}} -> result
      {:ok, result} -> result
      _ -> 
        case opts[:id] do
          id when is_binary(id) ->
            Logger.debug("ContextFetcher: RPC to #{inspect pid} failed. Attempting Registry lookup for #{id}...")
            case ACN.Core.NodeRegistry.lookup(id) do
              {:ok, %{pid: new_pid}} when new_pid != pid ->
                rpc_call(new_pid, call, default, Keyword.delete(opts, :id))
              _ ->
                log_rpc_failure(call, pid, opts)
                default
            end
          _ ->
            log_rpc_failure(call, pid, opts)
            default
        end
    end
  end

  defp log_rpc_failure(call, pid, opts) do
    if !opts[:silent] do
       Logger.warning("ContextFetcher Agent: RPC call #{call} failed for #{inspect pid}")
    else
       Logger.debug("ContextFetcher Agent: RPC call #{call} failed silently for #{inspect pid}")
    end
  end
end
