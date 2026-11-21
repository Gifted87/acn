defmodule ACN.Agents.TaskManager do
  @moduledoc """
  The TaskManager agent orchestrates the decomposition of high-level tasks into batched sub-tasks.
  In Intermediate Nodes, it uses a single AI bot (tm_planner) to generate a Directed Acyclic Graph (DAG)
  represented as sequential batches of parallel tasks.
  """
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.ProfileLoader
  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer
  alias ACN.Router
  alias ACN.Core.Utils.ID
  alias ACN.Observability.Panopticon

  # --- Public API ---

  def start_link(opts \\ []) do
    node_id = opts[:node_id] || "root"
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  defp via_tuple(node_id) do
    NodeRegistry.via_tuple(:task_manager, "#{node_id}_task_manager")
  end

  # --- Server Callbacks ---

  defmodule State do
    defstruct [
      :phase,
      :router
    ]
  end

  @impl true
  def init(opts) do
    node_id = opts[:node_id] || "root"
    router_state = %Router.State{
      agent_role: :task_manager,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    state = %State{
      phase: :idle,
      router: router_state
    }
    {:ok, state}
  end


  # --- Morphic State Handlers ---
  @impl true
  def handle_cast({:wake}, state) do
    Logger.info("TaskManager: Waking up (Morphic State: INTERMEDIATE). Ready to plan.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sleep}, state) do
    Logger.info("TaskManager: Entering Sleep Mode (Morphic State: LEAF).")
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_cast({:set_local_identity, _identity}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:routed_message, _sender, payload}, state) do
    GenServer.cast(self(), payload)
    {:noreply, state}
  end

  # --- Simplified Single-Bot Planning ---
  
  @impl true
  def handle_cast({:receive_implementation_package, package}, state) do
    Logger.info("TaskManager: Received Implementation Package. Generating Single-Bot Plan...")
    
    # 1. Prepare Variables for Profile
    task_desc = package.task_description
    rules = package.rules || []
    rules_text = (if is_list(rules), do: Enum.join(rules, "\n"), else: rules)
    
    vars = %{
      task_description: task_desc,
      rules: rules_text,
      context: package.full_context,
      deep_context: package.full_context,
      blueprint_spec: package[:blueprint_spec] || package["blueprint_spec"] || "No blueprint available."
    }
    
     # 2. Load Profile
    case ProfileLoader.load("tm_planner", vars) do
      {:ok, profile} ->
        run_planner_with_retry(profile, package, state, 5)
        
      {:error, reason} ->
         Logger.error("TaskManager: Failed to load tm_planner profile: #{inspect(reason)}")
    end
    {:noreply, state}
  end

  defp run_planner_with_retry(profile, package, state, attempts_left) do
    buffer = ContextBuffer.new(profile["system_prompt"])
    adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
    config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"]}
    
    Logger.info("TaskManager: Running Planner (Attempts left: #{attempts_left})...")
    
    case Pipeline.run(buffer, ["submit_plan"], config) do
      {:ok, msg, _, _} ->
          # CRITICAL VALIDATION: Check if bot actually called the tool
          tool_calls = Map.get(msg, :tool_calls) || []
          has_submit_plan_call = Enum.any?(tool_calls, fn tc ->
            get_in(tc, ["function", "name"]) == "submit_plan"
          end)
          
          if !has_submit_plan_call do
             if attempts_left > 1 do
                Logger.warning("TaskManager: Planner did NOT call submit_plan tool. Retrying with feedback...")
                # Inject feedback into task description
                feedback = "\n\n[CRITICAL SYSTEM ERROR]: You FAILED to call the submit_plan tool in your previous attempt. You MUST call the submit_plan tool with the batches array. DO NOT just describe the plan in text - you MUST use the tool!"
                updated_task = (package.task_description || "") <> feedback
                updated_package = Map.put(package, :task_description, updated_task)
                
                # Reconstruct vars for profile reload
                rules = updated_package.rules || []
                rules_text = (if is_list(rules), do: Enum.join(rules, "\n"), else: rules)
                updated_vars = %{
                  task_description: updated_task,
                  rules: rules_text,
                  context: updated_package.full_context,
                  deep_context: updated_package.full_context,
                  blueprint_spec: updated_package[:blueprint_spec] || updated_package["blueprint_spec"] || "No blueprint available."
                }
                
                {:ok, updated_profile} = ProfileLoader.load("tm_planner", updated_vars)
                run_planner_with_retry(updated_profile, updated_package, state, attempts_left - 1)
             else
                Logger.error("TaskManager: Planner did not call submit_plan tool after retries.")
                report_plan_failure("Bot Failed to Call submit_plan Tool (Exhausted Retries)", package, state.router)
             end
          else
             # Fix 4A: Pass working_path dynamically so extract_batches can validate
             msg_with_context = Map.put(msg, :working_path, package.working_path)
             batches = extract_batches(msg_with_context, state.router.node_id)
             
             if batches == [] do
                if attempts_left > 1 do
                   Logger.warning("TaskManager: Planner returned empty plan. Retrying...")
                   run_planner_with_retry(profile, package, state, attempts_left - 1)
                else
                   Logger.error("TaskManager: Planner returned empty plan after retries.")
                   report_plan_failure("Empty Plan / Parsing Error (Exhausted Retries)", package, state.router)
                end
             else
                # 4. Return Plan to Controller IMMEDIATELY
                plan = %{
                  batches: batches,
                  working_path: package.working_path,
                  parent_node_id: package.parent_node_id,
                 # Pass Blueprint back to Controller
                 blueprint_spec: package[:blueprint_spec] || package["blueprint_spec"]
               }

               # HSG: Inject intent into the Panopticon right before delivering the plan
               Enum.with_index(batches, fn batch, index ->
                 Panopticon.inject_intent(package.parent_node_id, index, batch)
               end)

               Logger.info("TaskManager: Plan Generated (#{length(batches)} batches). Sending to Controller.")
               Router.route({:plan_ready, plan}, {:local, :controller}, state.router)
             end
          end

      error ->
         if attempts_left > 1 do
            Logger.warning("TaskManager: Planner AI Failed. Retrying... Error: #{inspect(error)}")
            run_planner_with_retry(profile, package, state, attempts_left - 1)
         else
            Logger.error("TaskManager: Planner AI Failed after retries: #{inspect(error)}")
            report_plan_failure("AI Pipeline Error: #{inspect(error)}", package, state.router)
         end
    end
  end
        


  defp extract_batches(msg, node_id) do
     # 1. Try Tool Call (Primary Protocol)
     tool_call_result = 
       case Map.get(msg, :tool_calls) do
         [tr | _] -> 
           case tr do
             %{"function" => %{"name" => "submit_plan", "arguments" => args_json}} ->
                # REPAIR: Fix common model typo where array is closed with '}' followed by '['
                # e.g., [... }, [ ...
                fixed_json = String.replace(args_json, ~r/}\s*,\s*\[/, "], [")
                case Jason.decode(fixed_json) do
                  {:ok, %{"batches" => b}} when is_list(b) -> 
                    if validate_task_paths(b, msg[:working_path]), do: {:ok, canonical_batches(b, node_id)}, else: :error
                  {:ok, list} when is_list(list) -> 
                    if validate_task_paths(list, msg[:working_path]), do: {:ok, canonical_batches(list, node_id)}, else: :error
                  _ -> :error
                end
             _ -> :error
           end
         _ -> :error
       end

     case tool_call_result do
       {:ok, batches} -> batches
       :error ->
          # 2. Fallback: Parse raw content
          clean_content = 
            msg.content
            |> to_string()
            |> String.replace(~r/^```json\s*/, "") 
            |> String.replace(~r/\s*```$/, "")
            |> String.trim()
            # REPAIR here too
            |> String.replace(~r/}\s*,\s*\[/, "], [")

          case Jason.decode(clean_content) do
            {:ok, %{"batches" => b}} when is_list(b) -> 
              if validate_task_paths(b, msg[:working_path]), do: canonical_batches(b, node_id), else: []
            {:ok, list} when is_list(list) -> 
              if validate_task_paths(list, msg[:working_path]), do: canonical_batches(list, node_id), else: []
            _ -> 
               Logger.warning("TaskManager: Failed to parse plan from both Tool and Content.")
               Logger.debug("Raw Content: #{String.slice(msg.content || "", 0, 500)}")
               []
          end
     end
  end

  defp validate_task_paths(batches, working_path) when is_list(batches) do
    Enum.all?(batches, fn
      batch when is_list(batch) -> Enum.all?(batch, &has_valid_path?(&1, working_path))
      task when is_map(task) -> has_valid_path?(task, working_path)
      _ -> false 
    end)
  end

  defp has_valid_path?(task, working_path) do
    path = task["path"] || task[:path]
    # Fix 4A: Spatial containment check. Ensure the generated path is strictly within the parent's working directory.
    # We allow the path to exactly equal working_path, or be a subdirectory, but not completely disjoint.
    root = working_path || "/"
    is_binary(path) && String.length(path) > 1 && (String.starts_with?(path, "/") or String.starts_with?(path, "~")) && String.starts_with?(path, root)
  end

  defp report_plan_failure(reason, _package, router) do
      # Notify Controller of failure so it doesn't hang
      Router.route({:plan_failure, reason}, {:local, :controller}, router)
  end

  defp canonical_batches(batches, node_id) when is_list(batches) do
    if Enum.all?(batches, &is_map/1) do
      # A flat list of task objects is one parallel batch.
      [normalize_batch(batches, node_id)]
    else
      Enum.map(batches, fn
        batch when is_list(batch) -> normalize_batch(batch, node_id)
        task when is_map(task) -> normalize_batch([task], node_id)
        _ -> []
      end)
      |> Enum.reject(&(&1 == []))
    end
  end

  defp normalize_batch(batch, node_id) do
    batch
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_task_id/1)
    |> Enum.reject(&(&1[:id] == node_id))
  end

  defp normalize_task_id(task) when is_map(task) do
    id = task[:id] || task["id"]
    if id do
      Map.put(task, :id, ID.normalize(id))
    else
      task
    end
  end
end
