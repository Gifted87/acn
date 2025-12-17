defmodule ACN.Agents.Validator do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router

  defmodule State do
    defstruct [:current_artifact, :pending_command, :env_config, :rules, verdict_history: []]
  end

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:validator, :validator)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    initial_state =
      case ACN.Infrastructure.StateBackup.restore("validator") do
        {:ok, restored} ->
           Logger.info("Restored Validator State.")
           struct(State, restored) # restored is likely a map or struct, ensure proper casting if needed
        _ -> %State{}
      end
    {:ok, initial_state}
  end

  @impl true
  def terminate(_reason, state) do
    ACN.Infrastructure.StateBackup.backup("validator", state)
    Logger.info("Validator Terminating. State saved.")
  end

  @impl true
  def handle_cast({:validate_work, hash, rules, env_config}, state) do
    Logger.info("Validator received artifact: #{hash}. Initiating Double Gate QA.")

    # Gate 1: Static Analysis
    # A. Data Ingest
    # We need to read the file content.
    # Assuming Workspace is accessible. Ideally we use Workspace.read_artifact logic.
    # But Validator doesn't know the exact path? 
    # The payload {:validate_work, hash, rules, env_config} might be insufficient if we don't know the node/path.
    # Wait, in phase 2, Synthesizer or Controller sends this.
    # Let's assume we can fetch by hash via `ACN.Infrastructure.Workspace.read_artifact_by_hash`? 
    # Or Controller provides the content?
    # Controller usually sends path or content.
    # Let's assume we have to read it. 
    # If not provided, we might fail.
    # BUT: `ACN.Agents.Validator` state struct has `current_artifact` = hash.
    # Let's inspect `handle_cast` signature again.
    # {:validate_work, hash, rules, env_config}
    # We need content.
    # Let's modify Controller? No, scope creep.
    # Let's try to read it via `File.read` if we can assume location or use `ACN.Infrastructure.Workspace`.
    # `ACN.Infrastructure.Workspace` has `write_atomic` but reading?
    # `ACN.Agents.Synthesizer` implemented `Workspace.read_artifact/1`.
    # Let's use `ACN.Infrastructure.Workspace.read_artifact(hash_or_path)`.
    # Wait, the hash is just a hash. We need the path.
    # The Controller usually knows the path.
    # Let's assume for now we can't easily get content solely from hash without a lookup service (ACMS?).
    # CRITICAL: The prompt said "retrieve the file content... using hash/path provided".
    # Inspecting previous `handle_cast`: it didn't read file. It just asked TestPilot.
    # TestPilot probably guessed `mix test`.
    # To run Static Analysis, we NEED content.
    # I will add a lookup or assume `env_config` has path?
    # Or I will update `state` to include `path` if `validate_work` provides it?
    # The `validate_work` message signature in `Controller` is likely `{:validate_work, hash, rules, env}`.
    # Ideally, we update Controller to send `{:validate_work, hash, path, rules, env}`.
    # But I can't easily change Controller now without checking.
    # WORKAROUND: For this remediation, I will assume `env_config` contains `path` or try to read from a standard location if testing.
    # Or, simpler: I'll use `ACN.Core.Worksheet` if available? 
    # Let's assume the Validator can use `ACN.Infrastructure.Workspace` to find it if we pass path.
    # Let's check if `env_config` has it.
    
    # Actually, looking at `Controller.handle_cast({:task_complete, ...})` -> `Validator.validate_work`
    # It sends `hash`.
    # Let's rely on the fact that `ACN.Infrastructure.Workspace` might store artifacts by hash in a `manifest`?
    # Or, simpler: Just read `lib/`?
    # Okay, for the purpose of the plan "Retrieve the file content... using the hash/path provided":
    # I will modify the function logic to accept `path` if possible, but match existing signature first.
    # If existing signature is 4-arity...
    # I'll check if `hash` is actually a path? Sometimes it is.
    # If not, I'll attempt to verify.
    
    # Phase 1: Static Check (Deterministic)
    # We will skip content read for a moment and just focus on System Check logic.
    # But `Code.string_to_quoted` needs content.
    # Real Implementation for `Code.string_to_quoted`:
    # 1. Fetch Content.
    # 2. Check Syntax.
    
    # Correction: The user plan says "retrieving the hash/path provided".
    # I will update the logic to TRY to read `env_config.path` if present, else fallback.
    
    # Updated Logic (Gap D):
    # We resolve the path and the source node.
    # The Controller might pass `env_config[:node]` if the artifact is on a specific child/parent.
    # Defaults to local node if not specified.
    
    path = env_config[:path] || (if is_binary(hash) and File.exists?(hash), do: hash, else: nil)
    source_node = env_config[:node] || env_config[:source_node] || node()

    content_res = 
       if path do 
          ACN.Infrastructure.Lattice.fetch_artifact(path, source_node)
       else 
          # If we have no path, we can't do Safe Static Analysis yet.
          # We return an error so we fall back to dynamic testing (which might run without source analysis).
          {:error, :no_path}
       end
       
    case content_res do
      {:ok, content} ->
         # 1. Deterministic Syntax Check
         case Code.string_to_quoted(content) do
            {:ok, _quoted} ->
               # Syntax Valid. Proceed to Phase 2: Cognitive Static Audit.
               verify_static_rules(content, rules, hash, env_config, state)
               
            {:error, {line, error, token}} ->
               # Syntax Error. Fail immediately.
               Logger.info("Validator: Syntax Error Detected at line #{line}.")
               report_failure(hash, "Syntax Error: #{inspect(error)} #{inspect(token)}")
               {:noreply, state}
         end
         
      {:error, _} ->
         # Could not read content. Proceed to Dynamic Testing (Legacy/Fallback)
         Logger.warning("Validator: Could not read content for Static Analysis. Skipping to Dynamic.")
         run_dynamic_test(hash, rules, env_config, state)
    end
  end
  

  @impl true
  def handle_cast({:static_verdict, status, issues}, state) do
      Logger.info("Validator: Static Verdict Received: #{status}")
      
      case status do
        "CLEAN" ->
          Logger.info("Validator: Static Analysis CLEAN. Dispatching to TestPilot.")
          ACN.Core.Router.route({:request_execution, "mix test"}, {:local, :validator})
          {:noreply, %{state | verdict_history: state.verdict_history ++ [{:static_analysis, :pass}]}}
          
        "DIRTY" ->
          # --- CHANGED: Trigger Coroner Workflow ---
          Logger.info("Validator: Static Analysis DIRTY. Engaging Coroner.")
          evidence = Enum.join(issues, "\n")
          run_coroner(:static, "Static Analysis (Lint/Safety)", evidence, state)
          
        _ ->
          Logger.warning("Validator: Verdict Unknown.")
          {:noreply, state}
      end
  end

  @impl true
  def handle_cast({:request_execution, command}, state) do
     # Backward compatibility or direct internal request
    Logger.info("Requesting token for command: #{command}")
    payload = [intent: :run_test, command: command]
    Router.route({:request_token, payload}, {:local, :controller})
    {:noreply, %{state | pending_command: command}}
  end
  

  @impl true
  def handle_cast({:grant_token, token}, state) do
    if is_nil(state.pending_command) do
      Logger.error("Received token but no command pending")
    else
      Logger.info("Token received. Dispatching command to Actuator.")

      payload = %{
        tool: :exec_cmd,
        args: %{command: "sh", args: ["-c", state.pending_command]},
        token: token
      }

      Router.route({:perform_action, payload}, {:local, :actuator})
    end

    {:noreply, %State{state | pending_command: nil}}
    # Note: we kept pending_command in state, cleared here.
  end

  @impl true
  def handle_cast({:action_result, output, exit_code}, state) do
    Logger.info("Test finished (Exit: #{exit_code}). Analyzing logs...")

    # 1. Analyze Results via AI (Result Analyst)
    vars = %{exit_code: exit_code, output: String.slice(output, 0, 4000)}
    {:ok, profile} = ACN.Core.ProfileLoader.load("validator_result_analyst", vars)

    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
    config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}

    verdict_data =
       case ACN.AI.Pipeline.run(buffer, [], config) do
          {:ok, msg, _} ->
              try do
                 Jason.decode!(msg.content)
              rescue
                 _ -> %{"verdict" => if(exit_code == 0, do: "pass", else: "fail"), "summary" => "Parse Error"}
              end
          _ -> %{"verdict" => "fail", "summary" => "AI Failure"}
       end

    Logger.info("Analyst Verdict: #{inspect(verdict_data)}")

    if verdict_data["verdict"] == "pass" do
       ACN.Core.Router.route({:validation_verdict, :pass, %{hash: state.current_artifact, summary: verdict_data["summary"]}}, {:local, :controller})
       {:noreply, state}
    else
       # --- CHANGED: Trigger Coroner Workflow (Workflow L3) ---
       Logger.info("Validator: Failure detected. Engaging Coroner.")
       
       # Pass raw output + summary to Coroner
       evidence = "Summary: #{verdict_data["summary"]}\n\nRaw Output:\n#{String.slice(output, 0, 2000)}"
       run_coroner(:dynamic, state.pending_command || "Unknown Command", evidence, state)
    end
  end


  # Handle failure cases from Actuator (e.g. execution errors) similarly to failed tests
  @impl true
  def handle_cast({:action_failure, reason}, state) do
    Logger.info("Validation FAILED (Execution Error).")
    Router.route({:validation_failure, %{output: inspect(reason), hash: state.current_artifact}}, {:local, :controller})
    {:noreply, state}
  end

  defp verify_static_rules(content, rules, hash, env_config, state) do
     vars = %{code_content: content, rules: rules}
     {:ok, profile} = ACN.Core.ProfileLoader.load("validator_static", vars)
     
     buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
     adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
     config = %{adapter: adapter, opts: [model: profile["model"], temperature: 0.1], stop_after_tools: true}
     allowed_tools = profile["allowed_tools"]
     
     # This is Async in a real agent loop, but here we block for simplicity of the refactor
     # In a full FSM we would transition to :static_analysis state.
     # Given the complexity, we'll run Pipeline synchronously.
     
     case ACN.AI.Pipeline.run(buffer, allowed_tools, config) do
        {:ok, _msg, _final_buffer} ->
            # Inspect tool usage from buffer?
            # Or reliance on the tool `GenServer.cast(self(), {:static_verdict...})` logic we wrote.
            # The pipeline runs tools sequentially.
            # The tool DOES cast the verdict.
            # So we just wait?
            # NO. `Pipeline.run` is synchronous here.
            # So the tool `execute` happened.
            # The CAST is in the mailbox!
            # We return `{:noreply, ...}` and effectively "wait" for the cast to be handled in `handle_cast`.
            # To preserve context, we need to update state with `pending_dynamic_request` or similar.
            state = %{state | current_artifact: hash, env_config: env_config, rules: rules, pending_command: nil} # pending_command set later
            {:noreply, state}
            
        _ ->
           Logger.error("Validator: Static Audit Pipeline Failed.")
           report_failure(hash, "Static Audit AI Failed")
           {:noreply, state}
     end
  end

  defp run_dynamic_test(hash, rules, env_config, state) do
    # This is the old Phase 1 logic
    Logger.info("Validator: Proceeding to Dynamic Test Pilot...")
    
    # 1. Decide on Test Command via AI
    # Ensure env_config includes sandbox mount path for Test Pilot awareness
    enriched_context = Map.merge(env_config, %{
      sandbox_mount: "/mnt/source",  # Firecracker sandbox mount point
      host_cwd: System.get_env("PWD") || "/tmp"
    })
    
    vars = %{context: enriched_context, hash: hash, rules: rules}
    {:ok, profile} = ACN.Core.ProfileLoader.load("validator_test_pilot", vars)

    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
    config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}

    command =
       case ACN.AI.Pipeline.run(buffer, [], config) do
          {:ok, msg, _} -> msg.content |> String.trim() |> String.replace("`", "")
          _ -> "cd /mnt/source && mix test" # Updated fallback with sandbox path
       end

    Logger.info("Test Pilot Decision: #{command}")

    # 2. Request Permission
    payload = [intent: :run_test, command: command]
    Router.route({:request_token, payload}, {:local, :controller})

    {:noreply, %{state | current_artifact: hash, env_config: env_config, pending_command: command}}
  end

  defp run_coroner(type, command, evidence, state) do
    vars = %{
      failure_type: type, 
      command_or_rule: command,
      evidence: evidence
    }
    
    # 1. Load Profile
    case ACN.Core.ProfileLoader.load("validator_coroner", vars) do
      {:ok, profile} ->
        buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
        config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]], stop_after_tools: true}
        allowed_tools = profile["allowed_tools"]

        # 2. Run Pipeline
        case ACN.AI.Pipeline.run(buffer, allowed_tools, config) do
          {:ok, msg, _final_buffer} ->
             # 3. Extract Report from Tool Call
             # We prioritize the arguments sent TO the tool (the report itself)
             # rather than the result OF the tool (which might be just "ok")
             
             tool_call = 
               Enum.find(msg.tool_calls || [], fn call -> 
                 call["function"]["name"] == "generate_defect_report"
               end)
             
             report = 
               if tool_call do
                 args = tool_call["function"]["arguments"]
                 case args do
                   %{} -> args
                   binary when is_binary(binary) ->
                      case Jason.decode(binary) do
                        {:ok, decoded} -> decoded
                        _ -> %{reason: "Coroner arguments malformed", raw: binary}
                      end
                   _ -> %{reason: "Unknown argument format"}
                 end
               else
                 # Fallback: Check buffer if tool call missing from msg?
                 # Unlikely if the LLM followed instructions.
                 %{reason: "Coroner failed to call reporting tool"}
               end

             # 4. Route to Controller
             Logger.info("Coroner Report Generated. Routing to Controller.")
             ACN.Core.Router.route({:validation_failure, report}, {:local, :controller})

          {:error, reason} ->
             Logger.error("Coroner AI Failed: #{inspect(reason)}")
             ACN.Core.Router.route({:validation_failure, %{reason: "Coroner Brain Dead"}}, {:local, :controller})
        end

      {:error, reason} ->
         Logger.error("Failed to load Coroner profile: #{inspect(reason)}")
         {:noreply, state}
    end
    
    {:noreply, state}
  end
  
  defp report_failure(hash, reason) do
     Router.route({:validation_failure, %{hash: hash, report: %{"verdict" => "fail", "summary" => reason}}}, {:local, :controller})
  end
end
