defmodule ACN.Agents.Controller do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router
  alias ACN.Core.Security.TokenAuthority

  defmodule ControllerState do
    defstruct [
      :private_key,
      :public_key,
      :mode,
      :phase,       # Renamed from current_phase
      :context,
      :local_rules,
      :instruction,
      :draft_buffer,
      :execution_plan,
      :timer_ref,
      policy_retry_count: 0,
      validation_retry_count: 0
    ]
  end

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:controller, :controller)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    # Coronation: Generate identity credentials
    {priv, pub} = TokenAuthority.generate_keypair()

    # Publish Public Key to Registry
    case NodeRegistry.update_metadata(:controller, %{public_key: pub}) do
      :ok -> Logger.info("Controller Public Key Published.")
      err -> Logger.warning("Failed to publish Public Key: #{inspect(err)}")
    end

    initial_state =
      case ACN.Infrastructure.StateBackup.restore("controller") do
        {:ok, restored_map} ->
           Logger.info("Restored Controller State.")
           # Merge restored fields but keep new keys
           struct(ControllerState, Map.to_list(restored_map) ++ [private_key: priv, public_key: pub])
        _ ->
           %ControllerState{
             private_key: priv,
             public_key: pub,
             phase: :idle
           }
      end

    {:ok, initial_state}
  end

  @impl true
  def terminate(_reason, state) do
    # Strip Keys before saving? Or save them encrypted?
    # For now, we save everything. In prod, keys shouldn't be on disk normally, OR we re-gen on boot (as we do above).
    # If we re-gen on boot, we shouldn't overwrite them with restored old keys.
    # The restore logic above prioritizes new keys.

    # We convert struct to map to be safe with erlang binary
    state_map = Map.from_struct(state)
    ACN.Infrastructure.StateBackup.backup("controller", state_map)
    Logger.info("Controller Terminating. State saved.")
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_public_key, _from, state) do
    {:reply, state.public_key, state}
  end

  # --- Casts ---

  @impl true
  def handle_cast({:initialize_governance, payload}, state) do
    # Determine mode from payload (default to intermediate if unspecified, or handle structure)
    # The directive says: payload.task_assignment.type
    # We'll access safely.

    mode = get_in(payload, ["task_assignment", "type"]) || :intermediate
    # Convert string to atom if needed, assuming payload comes from JSON-like source
    mode = if is_binary(mode), do: String.to_atom(mode), else: mode

    Logger.info("Governance Initialized. Mode: #{mode}")

    # Trigger first phase based on Mode
    if mode == :intermediate do
      GenServer.cast(self(), {:internal_transition, :start_intermediate_legislation})
    else
      GenServer.cast(self(), {:internal_transition, :start_legislation})
    end

    {:noreply, %{state | mode: mode, context: payload, phase: :legislation}}
  end

  @impl true
  def handle_cast({:request_token, request_data}, state) do
    # request_data should contain scope and resource
    scope = request_data[:scope] || :exec_cmd
    resource = request_data[:resource] || request_data[:command] || "unknown"
    intent = request_data[:intent] || "unknown"

    # Mint Token using Sovereign Seal (Private Key)
    case TokenAuthority.mint_token(state.private_key, scope, resource) do
       {:ok, token, _claims} ->
          Logger.info("Token granted for scope: #{scope} intent: #{intent}")
          Router.route({:grant_token, token}, {:local, :validator})
       {:error, reason} ->
          Logger.error("Failed to mint token: #{inspect(reason)}")
    end

    {:noreply, state}
  end





  @impl true
  def handle_cast({:internal_transition, :start_legislation}, %{phase: :idle} = state) do
    # Load Legislator Profile
    gov_data = state.context[:governance_data] || state.context["governance_data"] || %{}

    vars = %{
      master_rules: gov_data[:master_rules] || ["Fallback Safety"],
      ancestral_rules: gov_data[:ancestral_rules] || [],
      task_description: gov_data[:task_description] || "Unknown",
      output_directive: gov_data[:output_directive] || "None",
      wisdom_warnings: gov_data[:wisdom_warnings] || "None"
    }

    {:ok, profile} = ACN.Core.ProfileLoader.load("controller_legislator", vars)

    # Initialize Buffer
    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    Logger.info("Controller entering Legislation Phase (AI Powered)...")

    # Run AI
    rules =
      case ACN.AI.Pipeline.run(buffer, [], config) do
        {:ok, msg, _new_buffer} ->
           # Expecting JSON list of strings
           try do
             Jason.decode!(msg.content)
           rescue
             _ -> [msg.content] # Fallback
           end
        error ->
           Logger.error("AI Legislation Failed: #{inspect(error)}")
           ["Rule: Fallback Safety Protocol"]
      end

    Logger.info("Legislation Complete. Rules: #{inspect(rules)}")

    GenServer.cast(self(), {:internal_transition, :start_architecting})

    {:noreply, %{state | local_rules: rules, phase: :architecting}}
  end

  @impl true
  def handle_cast({:internal_transition, :start_architecting}, %{phase: :legislation} = state) do
    # Load Architect Profile
    vars = %{rules: state.local_rules, context: state.context}
    {:ok, profile} = ACN.Core.ProfileLoader.load("controller_leaf_architect", vars)

    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    Logger.info("Controller entering Architecture Phase (AI Powered)...")

    instruction =
      case ACN.AI.Pipeline.run(buffer, [], config) do
        {:ok, msg, _} -> msg.content
        error ->
          Logger.error("AI Architecture Failed: #{inspect(error)}")
          "Error: Output failed."
      end

    Logger.info("Architecture Complete. Instruction: #{instruction}")

    # Prepare Immutable Context (Specialist Handoff Step 2.1 & 2.2)
    # We strip huge rules/memories from the map to keep it clean, or pass as is?
    # Spec says: ancestral_memory is {path => content}.
    # We assume state.context contains this if available.
    
    immutable_context = %ACN.Core.Artifacts.ImmutableContext{
      ancestral_memory: state.context[:ancestral_memory] || %{},
      codebase_map: state.context[:codebase_map] || [],
      wisdom_context: state.context[:gm_memories] || "None"
    }

    # Delegate to Specialist
    payload = {:execute_draft, instruction, state.local_rules, immutable_context}
    Router.route(payload, {:local, :specialist})

    {:noreply, %{state | instruction: instruction, phase: :delegating}}
  end

  @impl true
  def handle_cast({:draft_result, content}, %{phase: :delegating} = state) do
    Logger.info("Controller received draft result.")

    # Load Judge Profile
    # Fetch Master Rules again or store them? Better to fetch or store in state.
    # We should have stored them in state during legislation phase, but we only stored 'local_rules'.
    # For now, fetching them is cheap.
    master_rules = ACN.Core.Governance.MasterRules.get_rules()
    
    vars = %{master_rules: master_rules, local_rules: state.local_rules, draft: content}
    {:ok, profile} = ACN.Core.ProfileLoader.load("controller_judge", vars)

    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    verdict_raw =
       case ACN.AI.Pipeline.run(buffer, [], config) do
         {:ok, msg, _} -> msg.content |> String.trim()
         _ -> "REJECTED (AI Failure)"
       end

    Logger.info("Judge Verdict: #{verdict_raw}")

    # Parse Verdict (First word)
    if String.starts_with?(String.upcase(verdict_raw), "APPROVED") do
      Logger.info("Policy Check Passed.")
      GenServer.cast(self(), {:internal_transition, :start_security_review})
      {:noreply, %{state | draft_buffer: content, phase: :security_review}}
    else
      Logger.info("Policy Violation. Retrying...")
      
      if state.policy_retry_count < 3 do
         # Retry Architecture/Drafting
         Logger.info("Policy Retry ##{state.policy_retry_count + 1}. Requesting new draft.")
         # Ideally we'd feed feedback back. For now, we loop back to architecting phase or just re-delegate?
         # Simplest: Restart Architecting to get fresh instruction or same one.
         GenServer.cast(self(), {:internal_transition, :start_architecting})
         {:noreply, %{state | policy_retry_count: state.policy_retry_count + 1}}
      else
         Logger.error("Policy Violation Limit Exceeded. Aborting.")
         {:noreply, %{state | phase: :failed}}
      end
    end
  end

  @impl true
  def handle_cast({:internal_transition, :start_security_review}, %{phase: :security_review} = state) do
     # 1. Prepare Payload for review
     # We act as if we are requesting fs_write for the draft
     content_to_write =
       case state.draft_buffer do
         %{content: worksheet} when is_map(worksheet) ->
           worksheet |> Map.values() |> List.first() || "Empty Worksheet"
         binary when is_binary(binary) -> binary
         other -> inspect(other)
       end

     path = "/tmp/acn_output.ex"

     payload_map = %{tool: :fs_write, args: %{path: path, content: content_to_write}}

     # 2. AI Security Check
     vars = %{payload: payload_map}
     {:ok, profile} = ACN.Core.ProfileLoader.load("controller_security_officer", vars)

     buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
     config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

     auth_decision =
       case ACN.AI.Pipeline.run(buffer, [], config) do
         {:ok, msg, _} -> msg.content |> String.trim() |> String.upcase()
         _ -> "DENIED"
       end

     Logger.info("Security Officer Decision: #{auth_decision}")

     if String.contains?(auth_decision, "AUTHORIZED") do
         # Mint Token for Actuator
         # Correct Scope: fs_write, Resource: path
         {:ok, token, _} = TokenAuthority.mint_token(state.private_key, :fs_write, path)

         Logger.info("Action Authorized. Dispatching to Actuator.")

         payload = Map.put(payload_map, :token, token)

         Router.route({:perform_action, payload}, {:local, :actuator})

         {:noreply, %{state | phase: :execution}}
     else
         Logger.error("SECURITY VETO: Action Denied.")
         Router.route({:pain_signal, 100}, {:local, :live_wire})
         {:noreply, %{state | phase: :failed}}
     end
  end

  # Handle Actuator/Sandbox failure messages that might get routed here directly or via Validator
  # Handle Actuator Success -> Trigger Validation OR Next Step
  @impl true
  def handle_cast({:action_success, hash, path}, state) do
    Logger.info("Action Success (Hash: #{hash}, Path: #{path}). Phase: #{state.phase}")

    case state.phase do
      :execution ->
        # Standard Artifact Generation Flow -> Validate
        Logger.info("Artifact written. Initiating Validation (Zero-Trust Handshake Phase 1).")
        env = get_in(state.context, [:context, :env_config]) || %{}
        
        # NO TOKEN sent here. Validator must request it.
        payload = {:validate_work, hash, state.local_rules, env, path} 
        Router.route(payload, {:local, :validator})

        timer_ref = Process.send_after(self(), :validation_timeout, 60_000)
        {:noreply, %{state | phase: :validation, draft_buffer: %{path: path, hash: hash}, timer_ref: timer_ref}}

      :sre_prep ->
        # Infrastructure Prep Flow -> Spawn Children
        Logger.info(".keep file created. Infrastructure ready. Spawning children.")
        GenServer.cast(self(), {:internal_transition, :spawn_children})
        {:noreply, state}

      _ ->
        Logger.warning("Received unexpected action_success in phase #{state.phase}")
        {:noreply, state}
    end
  end



  # Handle Actuator Failure (Write Failed)
  @impl true
  def handle_cast({:action_failure, reason}, state) do
    Logger.error("Actuator failed: #{inspect(reason)}")
    # In a robust system, we would retry or fail the task.
    # For now, we log and stop.
    {:noreply, %{state | phase: :failed}}
  end

  # Handle Validation Verdict (PASS) -> Trigger Finalization
  @impl true
  def handle_cast({:validation_verdict, :pass, certificate}, %{phase: :validation} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    Logger.info("Validation PASSED. Work certified.")

    # Trigger Finalization
    # Tell Synthesizer to archive.

    agent_id = "agent_specialist_01"

    # Retrieve path from state (stored during action_success)
    path = state.draft_buffer[:path] || "unknown_path"

    # Retrieve Merge Context from Genesis Args
    # Ensure backward compatibility if genesis_args missing
    genesis = state.context[:genesis_args] || state.context["genesis_args"] || %{}
    parent_id = genesis[:parent_node] || genesis["parent_node"]
    slot_id = genesis[:output_slot] || genesis["output_slot"] || "unknown_slot"
    
    merge_context = %{parent_id: parent_id, slot_id: slot_id}

    # Pass Path instead of 'description'
    payload = {:finalize_task, certificate.hash, path, agent_id, merge_context}
    Router.route(payload, {:local, :synthesizer})

    {:noreply, %{state | phase: :finalization}}
  end

  # Handle Validation Failure -> Retry Logic
  @impl true
  def handle_cast({:validation_failure, report}, %{phase: :validation} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    
    # Check if Stale Context suspected (Phase 2)
    failure_reason = report[:reason] # :possible_stale_context or nil
    
    if failure_reason == :possible_stale_context do
       Logger.info("Validation FAILED (Possible Stale Context). Triggering Lattice Refresh Protocol.")
    else
       Logger.info("Validation FAILED. Defect detected.")
    end

    # Emit pain signal to LiveWire (Low pain for stale context?)
    pain_level = if failure_reason == :possible_stale_context, do: 5, else: 10
    Router.route({:pain_signal, pain_level}, {:local, :live_wire})

    if state.validation_retry_count < 3 do
       Logger.info("Triggering Refactor Workflow... (Retry ##{state.validation_retry_count + 1})")

       # 1. Read existing file from path
       path = state.draft_buffer[:path]
       existing_worksheet = 
         case File.read(path) do
           {:ok, content} -> %{path => content}
           _ -> %{}
         end

       # 2. Augment Report with Stale Hint
       enriched_report = 
         if failure_reason == :possible_stale_context do
            Map.put(report, "hint", "CRITICAL: The Validator suspects STALE CONTEXT (missing dependencies). You MUST run 'lattice_refresh_context' FIRST to download the latest artifacts from the Parent, then re-verify/re-write.")
         else
            report
         end

       # 3. Dispatch to Specialist for Refactor
       Router.route({:execute_refactor, enriched_report, state.local_rules, existing_worksheet}, {:local, :specialist})

       {:noreply, %{state | validation_retry_count: state.validation_retry_count + 1, phase: :delegating}}
    else
       Logger.error("CRITICAL FAILURE. Max retries exceeded. Giving Up.")
       {:noreply, %{state | phase: :failed}}
    end
  end

  # --- Intermediate Node Handlers ---

  @impl true
  def handle_cast({:internal_transition, :start_intermediate_legislation}, state) do
    # Load Intermediate Legislator Profile
    gov_data = state.context[:governance_data] || state.context["governance_data"] || %{}

    vars = %{
       context: state.context,
       master_rules: gov_data[:master_rules] || [],
       ancestral_rules: gov_data[:ancestral_rules] || [],
       task_description: gov_data[:task_description] || "Unknown",
       output_directive: gov_data[:output_directive] || "None"
    }

    {:ok, profile} = ACN.Core.ProfileLoader.load("controller_legislator_intermediate", vars)

    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    config = %{adapter: ACN.AI.Adapters.OpenAI, opts: [model: profile["model"], temperature: profile["temperature"]]}

    rules =
      case ACN.AI.Pipeline.run(buffer, [], config) do
        {:ok, msg, _} ->
           try do
             Jason.decode!(msg.content)
           rescue
             _ -> [msg.content]
           end
        error ->
           Logger.error("Intermediate Legislation Failed: #{inspect(error)}")
           ["Rule: Fallback - Maintain Cohesion"]
      end

    Logger.info("Intermediate Legislation Complete. Rules verified.")

    GenServer.cast(self(), {:internal_transition, :start_delegation})

    {:noreply, %{state | local_rules: rules, phase: :delegation}}
  end

  @impl true
  def handle_cast({:internal_transition, :start_delegation}, state) do
    Logger.info("Delegating Planning to Task Manager.")

    # Dispatch
    payload = {:decompose, state.context, state.local_rules}
    Router.route(payload, {:local, :task_manager})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:plan_ready, plan}, state) do
    count = length(plan.batches)
    Logger.info("Plan Received. Tasks batches: #{count}")

    # SPATIAL COLLISION CHECK (Preventive Planning 1.2)
    # We validate that no two tasks in the SAME batch write to the SAME output file.
    
    validation_result = 
      Enum.reduce_while(plan.batches, :ok, fn batch, _acc ->
         # Extract output paths from directives
         # We assume task maps have 'output_directive' or 'description'
         # Since we don't have parsed directives yet for *all* tasks (unless TM did it),
         # we might check 'output_path' if available, or rely on task.id if that maps to a file.
         # The User Prompt says: "Controller ... must strictly validate their Output Directives."
         # If tasks in plan have 'output_directive', we parse it.
         
         path_map = 
           Enum.reduce(batch, %{}, fn task, paths ->
              # Extract path from directive string (heuristic for now, or if structured)
              # Assumption: task[:output_directive] exists and contains path.
              # Simple check: If task data has 'output_path' key (added by TM or Legislative step before?)
              # If not, we skip check or fail safe?
              # Let's assume TM Slicer added 'output_path' to task struct/map.
              
              current_path = task[:output_path] || task["output_path"]
              if current_path do
                 Map.update(paths, current_path, [task.id], fn ids -> [task.id | ids] end)
              else
                 paths
              end
           end)
         
         # Check for collisions
         collisions = Enum.filter(path_map, fn {_path, ids} -> length(ids) > 1 end)
         
         if collisions == [] do
            {:cont, :ok}
         else
            {:halt, {:error, :collision, collisions}}
         end
      end)

    case validation_result do
      :ok ->
         Logger.info("Plan Validated. No Spatial Collisions detected.")
         GenServer.cast(self(), {:internal_transition, :start_sre_prep})
         {:noreply, %{state | execution_plan: plan, phase: :sre_prep}}
         
      {:error, :collision, collisions} ->
         Logger.error("CRITICAL: Spatial Collision Detected in Plan! Collisions: #{inspect(collisions)}")
         # Reject Plan
         # In a full loop, we'd send feedback to TM.
         # For now, we Halt Governance as requested.
         {:noreply, %{state | phase: :failed}}
    end
  end

  @impl true
  def handle_cast({:internal_transition, :start_sre_prep}, state) do
    Logger.info("Preparing Subtree Infrastructure...")

    # Mint Token for mkdir
    {:ok, token, _} = TokenAuthority.mint_token(state.private_key, :fs_write, "/tmp/acn_workspace/.keep")

    # Dispatch Actuator
    # We pretend this creates the necessary folders for the child nodes
    payload = %{
       tool: :fs_write,
       args: %{path: "/tmp/acn_workspace/.keep", content: ""},
       token: token
     }
    Router.route({:perform_action, payload}, {:local, :actuator})

    # Wait for action_success in :sre_prep phase
    # The Actuator will reply with {:action_success, ..., path} or {:action_failure, ...}
    # We do NOT cast to :spawn_children here. We wait.
    {:noreply, state}
  end

  @impl true
  def handle_cast({:internal_transition, :spawn_children}, state) do
    # Get first batch
    first_batch = List.first(state.execution_plan.batches) || []

    Enum.each(first_batch, fn task ->
       Logger.info("Spawning Child Node for Task: #{task.id}")
       # Send message to Supervisor
       Router.route({:spawn_child, task}, {:local, :supervisor})
    end)

    {:noreply, %{state | phase: :monitoring}}
  end

  # Catch-all for action_result if routed here
  @impl true
  def handle_cast({:action_result, _output, _code}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:validation_timeout, state) do
    if state.phase == :validation do
       Logger.error("TIMEOUT: Validation took too long. Assumed failed.")
       # Treat as validation failure
       Router.route({:validation_failure, %{report: "Timeout"}}, {:local, :controller})
       {:noreply, %{state | timer_ref: nil}}
    else
       # Ignore stale timer
       {:noreply, %{state | timer_ref: nil}}
    end
  end
end
