defmodule ACN.Agents.Controller do
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Router
  alias ACN.Core.Security.TokenAuthority
  alias ACN.Core.Utils.ID
  alias ACN.Observability.Emitter

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
      :security_token,           # FROM SUPERVISOR
      :implementation_directive, # FROM LEGISLATOR (Leaf)
      :legislation_result,       # FROM LEGISLATOR (Blueprint)
      :working_path,             # INTERMEDIATE: Full path for child nodes
      :implementation_package,   # INTERMEDIATE: Combined rules + plan
      :batches,                  # INTERMEDIATE: Batched tasks from TaskManager
      :current_batch_index,      # INTERMEDIATE: Index of current batch
      :batch_completions,        # INTERMEDIATE: Track completions in current batch
      :monitored_tasks,          # INTERMEDIATE: Map of {monitor_ref => task_id} for crash detection
      :is_root,                  # Whether this is the root node of the organism
      :blueprint_spec,           # INTERMEDIATE: Preserved Blueprint Spec for Children
      node_id: nil,              # Unique ID for this node
      policy_retry_count: 0,
      validation_retry_count: 0,
      router: %Router.State{},
      # Specification Fidelity Fields
      original_specification: nil,   # Full root technical specification
      specification_depth: 0,         # Depth in hierarchy (0=root)
      specification_metadata: nil     # Metadata about specification
    ]
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    node_id = opts[:node_id] || "root"
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  defp via_tuple(node_id) do
    NodeRegistry.via_tuple(:controller, "#{node_id}_controller")
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    node_id = opts[:node_id] || "root"
    # Initialize Router
    router_state = %Router.State{
      agent_role: :controller,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    # SECURITY: Attempt to restore existing keys from StateBackup first
    # This prevents token invalidation on Controller restart
    {priv, pub, is_restored} = 
      case ACN.Infrastructure.StateBackup.restore("controller", node_id) do
        {:ok, restored_map} when is_map(restored_map) ->
          # Check if keys exist in backup
          if restored_map[:private_key] && restored_map[:public_key] do
            Logger.info("Controller: Restored existing RSA key pair from backup.")
            {restored_map[:private_key], restored_map[:public_key], true}
          else
            Logger.info("Controller: No keys in backup. Generating new key pair.")
            TokenAuthority.generate_keypair() |> Tuple.append(false)
          end
        _ ->
          Logger.info("Controller: No backup found. Generating new key pair.")
          TokenAuthority.generate_keypair() |> Tuple.append(false)
      end

    # If we generated new keys, immediately persist them
    if !is_restored do
      Logger.info("Controller: Persisting new key pair to StateBackup.")
      ACN.Infrastructure.StateBackup.backup("controller", %{
        private_key: priv,
        public_key: pub,
        phase: :idle
      }, node_id)
    end

    # Publish Public Key to Registry (always, in case Registry was reset)
    case NodeRegistry.update_metadata("#{node_id}_controller", %{public_key: pub}) do
      :ok -> Logger.info("Controller Public Key Published.")
      err -> Logger.warning("Failed to publish Public Key: #{inspect(err)}")
    end

    # Build initial state (restore other fields if available)
    initial_state =
      case ACN.Infrastructure.StateBackup.restore("controller", node_id) do
        {:ok, restored_map} when is_map(restored_map) ->
           Logger.info("Restored Controller State.")
           ACN.Observability.AuditLogger.log_event(node_id, "STATE_RESTORE", "Restored from backup")
           # Merge restored fields with our keys
           struct(ControllerState, Map.to_list(restored_map) ++ [private_key: priv, public_key: pub, router: router_state, node_id: node_id])
        _ ->
           ACN.Observability.AuditLogger.log_event(node_id, "STATE_INIT", "Started clean state")
           %ControllerState{
             private_key: priv,
             public_key: pub,
             phase: :idle,
             node_id: node_id,
             router: router_state
           }
      end

    {:ok, initial_state}
  end

  @impl true
  def terminate(_reason, state) do
    # SECURITY: Always persist keys to prevent token invalidation on restart
    # Keys are persisted in encrypted format by StateBackup
    state_map = Map.from_struct(state)
    ACN.Infrastructure.StateBackup.backup("controller", state_map)
    Logger.info("Controller Terminating. State (including keys) saved.")
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_public_key, _from, state) do
    {:reply, state.public_key, state}
  end

  # --- Casts ---

  @impl true
  def handle_cast({:routed_message, _sender, payload}, state) do
    # Unwrap routed message and handle it
    GenServer.cast(self(), payload)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:rescue, state) do
    Logger.info("Controller: RESCUE SIGNAL RECEIVED. Unfreezing and resetting retry count.")
    # Transition back to legislating to restart the loop
    ACN.Observability.AuditLogger.log_event(state.node_id, "PHASE_TRANSITION", "Entering LEGISLATING phase")
    Emitter.flush_and_broadcast(state.phase || :frozen, :legislating, state.node_id)
    {:noreply, %{state | phase: :legislating, policy_retry_count: 0}}
  end

  @impl true
  def handle_cast({:child_handshake_complete}, state) do
    Logger.debug("Controller: Received child_handshake_complete signal.")
    {:noreply, state}
  end


  @impl true
  def handle_cast({:initialize_governance, payload}, state) do
    # Determine mode from payload (default to intermediate if unspecified, or handle structure)
    # The directive says: payload.task_assignment.type
    # We'll access safely.

    mode = 
      get_in(payload, [:task_assignment, :type]) || 
      get_in(payload, ["task_assignment", "type"]) || 
      :intermediate
    # Convert string to atom if needed, assuming payload comes from JSON-like source
    mode = if is_binary(mode), do: String.to_atom(mode), else: mode

    Logger.info("Governance Initialized. Mode: #{mode}")

    # Extract node_id for workspace isolation
    node_id = 
      get_in(payload, [:genesis_args, :task]) ||
      get_in(payload, ["genesis_args", "task"]) ||
      get_in(payload, [:node_id]) ||
      get_in(payload, ["node_id"]) ||
      "root"

    # Trigger first phase based on Mode
    new_phase = 
      case mode do
        :undetermined -> 
          Logger.info("Controller: Rank undetermined. Awaiting Supervisor classification...")
          :awaiting_identity
        :intermediate -> 
          Logger.info("Controller: Triggering Intermediate Legislation for Task: #{inspect(payload[:task] || payload["task"])}")
          GenServer.cast(self(), {:internal_transition, :start_intermediate_legislation})
          :legislation
        _ -> 
          Logger.info("Controller: Triggering Leaf Legislation for Task: #{inspect(payload[:task] || payload["task"])}")
          GenServer.cast(self(), {:internal_transition, :start_legislation})
          :legislation
      end
    
    # Extract specification fields for fidelity tracking
    original_spec = payload[:original_specification] || payload["original_specification"]
    spec_depth = payload[:specification_depth] || payload["specification_depth"] || 0
    spec_metadata = payload[:specification_metadata] || payload["specification_metadata"]
    
    # Store Token
    token = payload[:security_token] || payload["security_token"]

    working_path = payload[:working_path] || payload["working_path"] || state.working_path

    {:noreply, %{state | 
      mode: mode, 
      context: payload, 
      phase: new_phase, 
      security_token: token, 
      node_id: node_id,
      working_path: working_path,
      original_specification: original_spec,
      specification_depth: spec_depth,
      specification_metadata: spec_metadata
    }}
  end

  @impl true
  def handle_cast({:set_node_identity, identity, path, is_root}, state) do
    # This is called by the local Supervisor once its identity is determined
    # We allow the Supervisor to overrule any initial/legacy mode to ensure consistency
    
    new_mode = if is_binary(identity), do: String.to_atom(String.downcase(identity)), else: identity
    
    # Store the path in context and state for the legislator/children
    new_context = Map.put(state.context || %{}, :path, path)
    state = %{state | context: new_context, working_path: path}
    
    if state.mode != new_mode do
      Logger.info("Controller: Identity updated by Supervisor to #{new_mode} (was #{state.mode}). Is Root: #{inspect(is_root)}")
      
      # ROBUSTNESS: We NO LONGER trigger phase transitions here. 
      # Transitions are driven by initialize_governance to ensure context is present.
      {:noreply, %{state | mode: new_mode, is_root: is_root}}
    else
        {:noreply, %{state | is_root: is_root}}
    end
  end

  @impl true
  def handle_cast({:request_token, request_data}, state) do
    # request_data should contain scope and resource
    scope = request_data[:scope] || request_data["scope"] || :exec_cmd
    resource = request_data[:resource] || request_data["resource"] || request_data[:command] || request_data[:path] || "unknown"
    intent = request_data[:intent] || "unknown"

    # Mint Token using Sovereign Seal (Private Key)
    case TokenAuthority.mint_token(state.private_key, scope, resource) do
       {:ok, token, _claims} ->
          Logger.info("Token granted for scope: #{scope} intent: #{intent}")
          Router.route({:grant_token, token}, {:local, :validator}, state.router)
       {:error, reason} ->
          Logger.error("Failed to mint token: #{inspect(reason)}")
    end

    {:noreply, state}
  end





  @impl true
  def handle_cast({:internal_transition, :start_legislation}, state) do
    # ROBUSTNESS: Prevent double-execution of legislation phase if multiple signals arrive
    if state.phase != :legislation do
       Logger.warning("Controller: Ignoring start_legislation message (Current Phase: #{state.phase}). Likely race condition or duplicate signal.")
       {:noreply, state}
    else
      # Reset Retry Count for new task path? NO. 
      # We must preserve count for recursive retries.
      # Initial reset is handled by Identity Phase.
      # state = %{state | policy_retry_count: 0}
      
      # Load Legislator Profile
    # Context is now the flat payload from Supervisor
    # DEFENSIVE: Ensure all pillars exist to prevent EEx render errors
    ctx = 
      case state.context do
        %ACN.Infrastructure.Lattice.DeepContext{} = dc -> Map.from_struct(dc)
        map when is_map(map) -> map
        _ -> %{}
      end

    ctx = Map.merge(%{
      blueprint: "No inherited blueprint.",
      rules: %ACN.Infrastructure.Lattice.DeepContext.Rules{},
      worksheets: %{parent: nil, grandparent: nil, great_grandparent: nil},
      acms_results: [],
      task: "Unknown",
      path: state.working_path || "root"
    }, ctx)

    # Master and Ancestral Rules from Pillar II
    master = get_in(ctx, [:rules, Access.key(:master)]) || ctx["master_rules"] || ["Fallback Safety"]
    ancestral = get_in(ctx, [:rules, Access.key(:ancestral)]) || ctx["ancestral_rules"] || []
    
    # Task Description: Pillar V
    task_desc = ctx[:task] || ctx["task"] || ctx[:task_description] || "Unknown"
    
    # Path/Directive: Pillar VI
    out_dir = ctx[:path] || ctx["path"] || ctx[:output_directive] || "None"
    
    # Wisdom (ACMS): Pillar IV
    wisdom_raw = ctx[:acms_results] || ctx[:wisdom] || ctx["wisdom"] || []
    wisdom_text = 
      case wisdom_raw do
        list when is_list(list) -> 
           Enum.map_join(list, "\n", fn 
             %{fact_text: txt} -> "- #{txt}"
             w when is_binary(w) -> "- #{w}"
             _ -> "" 
           end)
        _ -> "No historical wisdom available."
      end

    # Ancestral Inventory (Worksheets): Pillar III
    # This is a Map of Maps: %{parent: %{}, grandparent: %{}, great_grandparent: %{}}
    worksheets = ctx[:worksheets] || ctx[:ancestral_inventory] || ctx[:ancestral_memory] || %{}

    # Blueprint: Pillar I
    blueprint_spec = ctx[:blueprint] || ctx[:blueprint_spec] || ctx["blueprint_spec"] || "No inherited blueprint."

    # Prepare Variables for Profile
    gov_data_map = %{
      master_rules: master,
      ancestral_rules: ancestral,
      task_description: task_desc,
      output_directive: out_dir,
      wisdom_warnings: wisdom_text,
      ancestral_inventory: worksheets,
      blueprint_spec: blueprint_spec
    }

    vars = %{
      governance_data: gov_data_map,
      deep_context: ctx # ctx is the DeepContext map/struct
    }

    {:ok, profile} = ACN.Core.ProfileLoader.load("controller_legislator", vars)

    # Initialize Buffer
    buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
    
    # Use Global Default Adapter (Ollama or TinyAgent) unless overridden
    adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
    config = %{
      adapter: adapter, 
      opts: [model: profile["model"], temperature: profile[ "temperature"], tool_choice: "ANY"],
      stop_after_tools: true
    }

    # HSG: pre-seed model/temperature into Process Dict so the Emitter captures them
    Process.put(:hsg_model, profile["model"])
    Process.put(:hsg_temperature, profile["temperature"])

    Logger.info("Controller entering Legislation Phase (AI Powered)...")

    # Run AI with Tool to ensure robust structured output
    # NEW: Updated to use 'submit_blueprint' as per profile.
    
      # Reset Retry Count? NO. We handle retries recursively.
      # state = %{state | policy_retry_count: 0}
      
      # Load Legislator Profile
      # ... (Loading Logic) ... (Redundant to repeat all lines if I can avoid it, but I must provide full chunk for replace)
      # actually I need to reuse the existing loading code, so I will select the block AFTER the profile load/run to minimize diff.

      # I will verify the block ranges first.
      # Lines 325-345 handle processing and transitioning.
      
      # Let's target the exact lines 325-345.
      
    env = %{node_id: state.node_id, working_path: state.working_path || ctx[:path] || ctx["path"] || "root"}
    legislative_output =
      case ACN.AI.Pipeline.run(buffer, ["submit_blueprint", "touch", "submit_legislation"], config, env) do
        {:ok, msg, new_buffer, _env} ->
           # Issue 3 Fix: push cognitive trace for shadow files
           ACN.Observability.Emitter.push_cognitive(%{
             raw_prompt: inspect(new_buffer, pretty: true),
             raw_response: msg.content || ""
           })

           # CRITICAL VALIDATION: Ensure bot actually called tools
           tool_calls = Map.get(msg, :tool_calls) || []
           
           if length(tool_calls) == 0 do
              Logger.warning("Controller (Leaf): Legislator did NOT call any tools. Triggering retry...")
              
              if state.policy_retry_count < 5 do
                 # Inject feedback and trigger async retry
                 new_count = state.policy_retry_count + 1
                 current_task = state.context[:task] || state.context["task"] || ""
                 feedback = "\n\n[CRITICAL SYSTEM ERROR]: You FAILED to call ANY tools in your previous attempt. You MUST call the submit_blueprint tool (at minimum). DO NOT just respond with text - you MUST use the tools!"
                 new_context = Map.put(state.context, :task, current_task <> feedback)
                 
                 # Trigger retry asynchronously
                 GenServer.cast(self(), {:internal_transition, :start_legislation})
                 # Update state for retry
                 Process.put(:retry_state, %{state | policy_retry_count: new_count, context: new_context})
              else
                 Logger.error("Controller (Leaf): Legislator failed to call tools after retries.")
                 # Trigger remediation asynchronously
                 Process.send_after(self(), {:trigger_remediation, "Leaf Legislator failed to call required tools."}, 100)
              end
              
              # Return fallback to allow graceful continuation
              %{rules: ["Rule: Fallback - Retry Triggered"], spec: "Fallback", path: nil, init: nil}
           else
              process_legislative_tools(msg, state)
           end
        error ->
           Logger.error("AI Legislation Failed: #{inspect(error)}")
           %{rules: ["Rule: Fallback Safety Protocol"], spec: "Fallback", path: nil, init: nil}
      end
    
    # Check if we need to apply retry state
    state = Process.get(:retry_state) || state
    Process.delete(:retry_state)

    # VALIDATION: Ensure Path is ABSOLUTE, a FILE (not dir), and PRESENT
    target_path = legislative_output[:path] || legislative_output["path"]
    
    # Path is invalid if: nil, empty, "root", a directory, or not absolute
    is_path_invalid = 
      is_nil(target_path) or 
      target_path == "" or 
      target_path == "root" or 
      File.dir?(target_path) or 
      !(String.starts_with?(target_path, "/") or String.starts_with?(target_path, "~"))

    if is_path_invalid do
       Logger.warning("Controller: Legislator provided an invalid or missing path '#{inspect(target_path)}'. A full ABSOLUTE FILE path is required. Retrying...")
       
       if state.policy_retry_count < 5 do
          # Increment Count
          new_count = state.policy_retry_count + 1
          
          # Feedback Loop: Inject error into Task Description for next run
          current_task = state.context[:task] || state.context["task"] || ""
          feedback = 
            cond do
              is_nil(target_path) or target_path == "" or target_path == "root" ->
                "\n[SYSTEM ERROR]: You failed to provide a target path. You MUST call a tool (like touch or submit_blueprint) with a full ABSOLUTE path to the file you intend to create/modify."
              File.dir?(target_path) ->
                "\n[SYSTEM ERROR]: Previous attempt produced '#{target_path}' which is a DIRECTORY. You MUST provide a full FILE path (e.g. including extension)."
              true ->
                "\n[SYSTEM ERROR]: Path '#{target_path}' is not an absolute path. It MUST start with '/'."
            end
          
          new_context = Map.put(state.context, :task, current_task <> feedback)
          
          GenServer.cast(self(), {:internal_transition, :start_legislation})
          {:noreply, %{state | policy_retry_count: new_count, context: new_context}}
       else
          Logger.error("Controller: Legislator failed to provide valid file path after 5 attempts.")
          handle_remediation("Legislator failed to provide valid file path.", state)
       end
    else
       Logger.info("Legislation Complete. Rules: #{inspect(legislative_output.rules)}")

       # SYNC PILLAR II: Update Supervisor with Local Rules
       Router.route({:update_local_rules, legislative_output.rules}, {:local, :supervisor}, state.router)
       
       # NEW: SYNC PILLAR I: Update Supervisor with Local Blueprint
       Router.route({:update_local_blueprint, legislative_output.spec}, {:local, :supervisor}, state.router)

       GenServer.cast(self(), {:internal_transition, :start_architecting})

       ACN.Observability.AuditLogger.log_event(state.node_id, "PHASE_TRANSITION", "Entering ARCHITECTING phase")
       Emitter.flush_and_broadcast(:legislation, :architecting, state.node_id)
       {:noreply, %{state | local_rules: legislative_output.rules, legislation_result: legislative_output, phase: :architecting, policy_retry_count: 0}}
    end
    end
  end
  





  @impl true
  def handle_cast({:internal_transition, :start_architecting}, state) do
    # STICT SEPARATION OF CONCERNS
    # Intermediate = Planner (Task Manager)
    # Leaf = Worker (Specialist)
    
    if state.mode == :leaf do
      Logger.info("[Leaf] Skipping Architecture Phase. Accepting Supervisor assignment as absolute instruction.")

      # 1. Extract the raw instruction from the context provided by Supervisor
      raw_instruction = 
        state.context[:task] ||                   # New Flattened Key
        state.context["task"] ||
        state.context[:task_description] || 
        state.context["task_description"] ||
        get_in(state.context, [:task_assignment, :description]) ||
        "Unknown Task"

      # 2. Create Implementation Directive
      # In this simplified flow, the 'Directive' is the combination of the Instruction + Rules + Context
      # The Legislator Phase (handled prior) generated 'local_rules' AND 'legislation_result'.
      
      # Use Blueprint Spec if available, otherwise raw instruction
      blueprint = state.legislation_result || %{}
      
      task_final = 
        if blueprint[:spec] do
           """
           TASK SUMMARY: #{raw_instruction}
           
           TECHNICAL SPECIFICATIONS (BLUEPRINT):
           #{blueprint.spec}
           """
        else
           raw_instruction
        end
      
      # Use Blueprint Path if available, otherwise Supervisor directive
      target_path_final = blueprint[:path] || state.context[:path] || state.context["path"]
      
      # Ensure target_path is not a directory
      # Ensure target_path is not a directory? NO.
      # We now allow directory targets so the Actuator (AI) can determine the filename.
      # The TokenAuthority now supports directory-scoped tokens.
      target_path_final = 
        if target_path_final && File.dir?(target_path_final) do
           Logger.info("[Leaf] Target is a directory. Delegating filename choice to Actuator.")
           target_path_final
        else
           target_path_final
        end

      directive = %{
        task: task_final,
        rules: state.local_rules,
        target_path: target_path_final,
        init_command: blueprint[:init],
        node_id: state.node_id,
        blueprint_spec: blueprint[:spec] || "No blueprint available.",
        full_context: %{state.context | 
          blueprint: blueprint[:spec] || state.context.blueprint,
          path: target_path_final
        }
      }



      # 3. DIRECT DELEGATION TO ACTUATOR (The Code Drafter)
      Logger.info("[Leaf] Delegating to ACTUATOR for Code Generation & Execution.")
      
      # We must mint a NEW token scoped to the target path for the Actuator
      {:ok, token, _claims} = ACN.Core.Security.TokenAuthority.mint_token(
          state.private_key, 
          :actuator, 
          directive.target_path, # Resource is the file path
          "controller",
          300 # 5 min TTL
      )
      
      payload = %{
        tool: :generate_implementation, # New Actuator Tool/Mode
        directive: directive,
        token: token,
        _sender: :controller
      }
      
      # Route to Actuator
      Router.route(payload, {:local, :actuator}, state.router)

      # 4. Transition to Execution (Waiting for Actuator)
      # We set a timeout for the Actuator
      timer = Process.send_after(self(), :delegation_timeout, 600_000) # 10 mins
      ACN.Observability.AuditLogger.log_event(state.node_id, "PHASE_TRANSITION", "Entering EXECUTION phase (Delegating to Actuator)")
      Emitter.flush_and_broadcast(:architecting, :execution, state.node_id)
      {:noreply, %{state | instruction: raw_instruction, implementation_directive: directive, phase: :execution, timer_ref: timer}}

    else
      # --- INTERMEDIATE NODE PATH ---
      Logger.info("[Intermediate] Architecting Phase redirected to unified Delegation.")
      
      # We just transition to :start_delegation, which handles packaging and sending to TaskManager
      GenServer.cast(self(), {:internal_transition, :start_delegation})
      Emitter.flush_and_broadcast(:architecting, :delegation, state.node_id)

      {:noreply, %{state | phase: :delegation}}

      {:noreply, %{state | phase: :delegation}}
    end
  end


  def handle_cast({:continue}, state) do
    Logger.info("Controller: CONTINUE command received. Resetting failure state and restarting implementation...")
    # Reset counts and return to execution
    new_state = %{state | phase: :execution, policy_retry_count: 0, validation_retry_count: 0}
    
    directive = state.implementation_directive
    token = state.security_token
    
    payload = %{
      tool: :generate_implementation,
      directive: directive,
      token: token,
      _sender: :controller
    }
    
    Router.route(payload, {:local, :actuator}, state.router)
    
    timer = Process.send_after(self(), :delegation_timeout, 600_000)
    {:noreply, %{new_state | timer_ref: timer}}
  end

  # --- Action Handlers (Moved here to group with other handle_cast) ---



  @impl true
  def handle_cast({:implementation_written, path, hash}, state) do
     Logger.info("Controller: Implementation Written at #{path} (Hash: #{hash}). Running Contract Verification...")
     if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

     # Phase 3: Check the output contract (file_manifest) before running the Judge.
     # This prevents nodes from claiming success without producing their committed files.
     # GUARD: blueprint_spec may be a plain string (spec text) rather than a map.
     blueprint_spec_map = if is_map(state.blueprint_spec), do: state.blueprint_spec, else: %{}
     file_manifest = blueprint_spec_map[:file_manifest] || blueprint_spec_map["file_manifest"] ||
                     (state.legislation_result || %{})[:file_manifest] || []
     working_path = state.working_path || Path.dirname(path)

     contract_result = ACN.Agents.Actuator.ContractVerifier.verify(working_path, file_manifest)

     case contract_result do
       {:error, missing_files} ->
         # Inject feedback and force remediation
         feedback = ACN.Agents.Actuator.ContractVerifier.build_feedback(working_path, missing_files)
         handle_remediation(feedback, state)

       _ ->
         # Contract satisfied (or no manifest = skip). Proceed to Judge.
         Logger.info("Controller: Contract OK. Triggering JUDGE (Static Verification).")
         case File.read(path) do
           {:ok, code} -> run_judge_validation(code, path, state)
           {:error, reason} ->
              Logger.error("Controller: Failed to read written file: #{inspect(reason)}")
              handle_remediation("File missing after write reported success.", state)
         end
     end
  end


  @impl true
  def handle_cast({:action_result, _output, _code}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:action_failure, reason}, state) do
    Logger.error("Actuator Action Failed: #{inspect(reason)}")
    handle_remediation(reason, state)
  end

  @impl true
  def handle_cast({:agent_error, agent_id, reason}, state) do
     Logger.error("Controller: External Agent Failure [#{agent_id}]: #{inspect(reason)}")
     handle_remediation("Agent Error: #{inspect(reason)}", state)
  end
  @impl true
  # --- Intermediate Node Handlers ---
  def handle_cast({:internal_transition, :start_intermediate_legislation}, state) do
    Logger.info("Controller (Intermediate): Received start_intermediate_legislation message. Current Phase: #{state.phase}")
    if state.phase != :legislation and state.phase != :idle do
       Logger.warning("Controller (Intermediate): Ignoring start_intermediate_legislation message (Current Phase: #{state.phase}).")
       {:noreply, state}
    else
       ctx = state.context
    
    task_desc = 
       ctx[:task] || 
       ctx["task"] ||
       ctx[:task_description] || 
       get_in(ctx, ["task_assignment", "description"]) ||
       "Unknown"

    working_path = 
      state.working_path ||
      ctx[:working_path] ||
      ctx["working_path"] ||
      ctx[:path] ||
      ctx["path"] ||
      ctx[:output_directive] ||
      "root"
      
    state = %{state | policy_retry_count: 0} 

    Logger.info("Controller (Intermediate): Starting Legislation for Task: #{task_desc}")

    # DEFENSIVE: Ensure all pillars exist to prevent EEx render errors
    ctx = 
      case state.context do
        %ACN.Infrastructure.Lattice.DeepContext{} = dc -> Map.from_struct(dc)
        map when is_map(map) -> map
        _ -> %{}
      end

    ctx = Map.merge(%{
      blueprint: "No inherited blueprint.",
      rules: %ACN.Infrastructure.Lattice.DeepContext.Rules{},
      worksheets: %{parent: nil, grandparent: nil, great_grandparent: nil},
      acms_results: [],
      task: "Unknown",
      path: state.working_path || "root"
    }, ctx)

    vars = %{
       context: state.context,
       master_rules: get_in(ctx, [:rules, Access.key(:master)]) || ctx["master_rules"] || [],
       ancestral_rules: get_in(ctx, [:rules, Access.key(:ancestral)]) || ctx["ancestral_rules"] || [],
       task_description: task_desc,
       output_directive: working_path,
       # Pillar I: Blueprint
       blueprint_spec: ctx[:blueprint] || ctx[:blueprint_spec] || "No blueprint available.",
       deep_context: ctx
    }

    case ACN.Core.ProfileLoader.load("controller_legislator_intermediate", vars) do
      {:ok, profile} ->
        buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
        config = %{
          adapter: adapter, 
          opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"],
          stop_after_tools: true
        }

        env = %{node_id: state.node_id, working_path: working_path}
        case ACN.AI.Pipeline.run(buffer, ["mkdir", "submit_blueprint", "submit_legislation"], config, env) do
          {:ok, msg, new_buffer, _} ->
            # Issue 3 Fix: push cognitive trace for shadow files
            ACN.Observability.Emitter.push_cognitive(%{
              raw_prompt: inspect(new_buffer, pretty: true),
              raw_response: msg.content || ""
            })

            tool_calls = Map.get(msg, :tool_calls) || []
            
            # CRITICAL VALIDATION: Ensure all 3 required tools were called
            required_tools = ["mkdir", "submit_blueprint", "submit_legislation"]
            called_tools = Enum.map(tool_calls, fn tc -> get_in(tc, ["function", "name"]) end)
            missing_tools = required_tools -- called_tools
            
            if length(missing_tools) > 0 do
               Logger.warning("Controller (Intermediate): Legislator did NOT call required tools: #{inspect(missing_tools)}. Retrying...")
               
               if state.policy_retry_count < 5 do
                  new_count = state.policy_retry_count + 1
                  current_task = state.context[:task] || state.context["task"] || ""
                  feedback = "\n\n[CRITICAL SYSTEM ERROR]: You FAILED to call ALL required tools. Missing: #{inspect(missing_tools)}. You MUST call ALL THREE tools: mkdir, submit_blueprint, submit_legislation. DO NOT just respond with text - you MUST use ALL the tools!"
                  new_context = Map.put(state.context, :task, current_task <> feedback)
                  
                  GenServer.cast(self(), {:internal_transition, :start_intermediate_legislation})
                  {:noreply, %{state | policy_retry_count: new_count, context: new_context}}
               else
                  Logger.error("Controller (Intermediate): Legislator failed to call required tools after retries.")
                  handle_remediation("Intermediate Legislator failed to call required tools: #{inspect(missing_tools)}", state)
               end
            else
              # 1. Process Tool Calls
              # We must handle 'mkdir' and 'submit_blueprint'
              
              results = Enum.reduce(tool_calls, %{rules: [], path: working_path, spec: nil, file_manifest: []}, fn tc, acc ->
                args_binary = tc["function"]["arguments"] || "{}"
                case tc["function"]["name"] do
                  "mkdir" ->
                    case safe_json_decode(args_binary) do
                      {:ok, args} ->
                        path = args["path"]
                        Logger.info("Bot Command: mkdir #{path}")
                        ACN.Tools.FileSystem.Mkdir.execute(args, %{node_id: state.node_id, working_path: working_path})
                        %{acc | path: path}
                      {:error, _} ->
                        Logger.error("Controller: Failed to decode mkdir arguments: #{args_binary}")
                        acc
                    end
                    
                  "submit_legislation" ->
                    case safe_json_decode(args_binary) do
                      {:ok, args} ->
                        rules = args["rules"] || []
                        Logger.info("Bot Command: submit_rules. Rules: #{length(rules)}")
                        %{acc | rules: rules}
                      {:error, _} ->
                        Logger.error("Controller: Failed to decode submit_legislation arguments: #{args_binary}")
                        acc
                    end

                  "submit_blueprint" ->
                    case safe_json_decode(args_binary) do
                      {:ok, args} ->
                        spec = args["technical_specifications"]
                        path = args["target_path"]
                        # Phase 2: Extract the file_manifest output contract.
                        manifest = args["file_manifest"] || []
                        Logger.info("Bot Command: submit_blueprint. Spec: #{String.slice(inspect(spec), 0, 50)}. Path: #{path}. Manifest: #{length(manifest)} files")
                        %{acc | spec: spec, path: path || acc.path, file_manifest: manifest}
                      {:error, _} ->
                        Logger.error("Controller: Failed to decode submit_blueprint arguments: #{args_binary}")
                        acc
                    end
                    
                  _ -> acc
                end
              end)
              
              # SYNC PILLAR II: Update Supervisor with Local Rules
              Router.route({:update_local_rules, results.rules}, {:local, :supervisor}, state.router)
              
              # NEW: SYNC PILLAR I: Update Supervisor with Local Blueprint
              Router.route({:update_local_blueprint, results.spec}, {:local, :supervisor}, state.router)
              
              # VALIDATION: Ensure Path is ABSOLUTE and valid for an Intermediate Node
              target_path = results.path
              workspace_root = Application.get_env(:acn, :workspace_root)
              
              is_path_invalid = 
                 is_nil(target_path) or 
                 target_path == "" or 
                 target_path == "root" or 
                 target_path == workspace_root or
                 !(String.starts_with?(target_path, "/") or String.starts_with?(target_path, "~"))

              if is_path_invalid do
                 Logger.warning("Controller (Intermediate): Legislator failed to provide a valid sub-directory path. Retrying...")
                 
                 if state.policy_retry_count < 5 do
                    new_count = state.policy_retry_count + 1
                    # Feedback Nudge
                    current_task = state.context[:task] || state.context["task"] || ""
                    feedback = "\n[SYSTEM ERROR]: You failed to establish a valid sub-directory for this intermediate task. You MUST call 'mkdir' with an absolute path to create a workspace for child nodes."
                    new_context = Map.put(state.context, :task, current_task <> feedback)
                    
                    GenServer.cast(self(), {:internal_transition, :start_intermediate_legislation})
                    {:noreply, %{state | policy_retry_count: new_count, context: new_context}}
                 else
                    Logger.error("Controller (Intermediate): Legislator failed path enforcement after retries.")
                    handle_remediation("Intermediate Legislator failed to provide valid workspace path.", state)
                 end
              else
                 # Transition to Delegation
                 GenServer.cast(self(), {:internal_transition, :start_delegation})
                 {:noreply, %{state | local_rules: results.rules, phase: :delegation, working_path: results.path, legislation_result: results, policy_retry_count: 0}}
              end
            end

          error ->
            Logger.error("Intermediate Legislation Pipeline Failed: #{inspect(error)}")
            GenServer.cast(self(), {:internal_transition, :start_delegation})
            {:noreply, %{state | phase: :delegation}}
        end

      {:error, reason} ->
        Logger.error("Failed to load intermediate legislator profile: #{inspect(reason)}")
        {:noreply, state}
    end
    end
  end

  @impl true
  def handle_cast({:internal_transition, :start_delegation}, state) do
    Logger.info("Delegating Planning to Task Manager with Implementation Package.")

    # Extract parent node ID from context
    parent_node_id = 
      state.context[:parent_node_id] ||
      state.context["parent_node_id"] ||
      Node.self()

    # Package implementation details with rules for Task Manager
    implementation_package = %{
      rules: state.local_rules,
      working_path: state.working_path,
      parent_node_id: parent_node_id,
      task_description: state.context[:task] || state.context["task"] || "Intermediate Task",
      # UPDATE CONTEXT: Ensure Planner sees the NEW working directory, not the parent's.
      full_context: %{state.context | 
          blueprint: state.legislation_result[:spec] || state.legislation_result["spec"] || state.context.blueprint,
          path: state.working_path
      },
      # Blueprint + File Manifest Propagation (Phase 2)
      blueprint_spec: state.legislation_result[:spec] || state.legislation_result["spec"] || "No technical blueprint provided.",
      file_manifest: state.legislation_result[:file_manifest] || state.legislation_result["file_manifest"] || []
    }

    # Store package in state for reference
    state = %{state | implementation_package: implementation_package}

    # Dispatch updated message format to Task Manager
    payload = {:receive_implementation_package, implementation_package}
    Router.route(payload, {:local, :task_manager}, state.router)

    {:noreply, state}
  end



  @impl true
  def handle_cast({:plan_ready, plan}, state) do
    batches = plan.batches
    Logger.info("Controller: Plan Received. Total Batches: #{length(batches)}")

    # Initialize Batch Tracking
    state = %{state | 
      batches: batches, 
      current_batch_index: 0,
      batch_completions: %{},
      # Preserve Blueprint for children
      blueprint_spec: plan[:blueprint_spec] || plan["blueprint_spec"]
    }

    # Start Phase: Spawning
    if length(batches) > 0 do
      spawn_batch(0, state)
    else
      Logger.warning("Controller: Received empty plan from TaskManager.")
      Router.route({:shutdown_request}, {:local, :supervisor}, state.router)
      {:noreply, %{state | phase: :completed}}
    end
  end

  @impl true
  def handle_cast({:plan_failure, reason}, state) do
    Logger.error("Controller: TaskManager failed to generate plan: #{inspect(reason)}")
    handle_remediation("Planning Failure: #{inspect(reason)}", state)
  end


  @impl true
  def handle_cast({:task_complete, child_id}, state) do
    child_id = ID.normalize(child_id)
    Logger.info("Controller: Child Task Completed: #{child_id}")

    # Update completions for current batch
    new_completions = Map.put(state.batch_completions || %{}, child_id, :completed)
    
    # 2024-03-14 Update: Leaf nodes do not manage batches. 
    # The :task_complete signal for a leaf node (from its local supervisor) 
    # should NOT trigger batch checking logic.
    if state.mode == :leaf do
       Logger.info("Controller: Leaf Node task marked complete in worksheet.")
       {:noreply, %{state | batch_completions: new_completions}}
    else
      current_batch_index = state.current_batch_index || 0
      current_batch = Enum.at(state.batches || [], current_batch_index)

      if is_nil(current_batch) do
        Logger.error("Controller: Batch is nil at index #{current_batch_index}")
        {:noreply, %{state | batch_completions: new_completions}}
      else
        # Check if all in current batch are done
        all_done = Enum.all?(current_batch, fn task ->
          id = ID.normalize(task[:id] || task["id"])
          status = Map.get(new_completions, id)
          Logger.debug("Controller: Checking task #{id} - Status: #{inspect(status)}")
          status == :completed
        end)

        Logger.info("Controller: Batch #{current_batch_index} Status - All Done: #{all_done}, Completions: #{inspect(Map.keys(new_completions))}")

        if all_done do
          Logger.info("Controller: Batch #{current_batch_index} Complete.")
          GenServer.cast(self(), {:batch_complete, current_batch_index})
          {:noreply, %{state | batch_completions: new_completions}}
        else
          {:noreply, %{state | batch_completions: new_completions}}
        end
      end
    end
  end

  @impl true
  def handle_cast({:batch_complete, completed_index}, state) do
     next_index = completed_index + 1
     
     # Safety check: ensure we're completing the CURRENT batch, not a stale one
     if completed_index != state.current_batch_index do
       Logger.warning("Controller: Ignoring stale batch_complete for index #{completed_index}, current is #{state.current_batch_index}")
       {:noreply, state}
     else
       if next_index < length(state.batches || []) do
          Logger.info("Controller: Proceeding to Batch #{next_index}")
          spawn_batch(next_index, %{state | current_batch_index: next_index, batch_completions: %{}})
       else
          Logger.info("Controller: All batches complete. Transitioning to Finalization.")
          GenServer.cast(self(), {:internal_transition, :finalize_work})
          {:noreply, %{state | phase: :finalizing}}
       end
     end
  end

  @impl true
  def handle_cast({:internal_transition, :run_judge_retry, buffer, path}, state) do
     run_judge_validation(buffer, path, state)
  end

  @impl true
  def handle_cast({:internal_transition, :finalize_work}, state) do
    Logger.info("Controller: Finalizing Intermediate Work. Aggregating Child Results...")

    # 1. Fetch Child Results from Supervisor (Worksheet)
    # Use local directory PID instead of registry lookup for child nodes
    supervisor_pid = state.router.local_directory[:supervisor]
    
    child_results = 
       if supervisor_pid && Process.alive?(supervisor_pid) do
         try do
           case GenServer.call(supervisor_pid, :get_child_results, 10_000) do
             {:ok, results} -> results
             _ -> []
           end
         catch
           :exit, _reason ->
             Logger.warning("Controller: Supervisor died during call. Proceeding with limited context.")
             []
         end
       else
         Logger.warning("Controller: Local supervisor missing or dead! Attempting to finalize with limited local context.")
         []
       end

    Logger.info("Controller: Found #{length(child_results)} child artifacts.")

    # 2. Synthesize Intermediate DBC
    # We aggregate the descriptions of the child results
    aggregated_knowledge = 
      Enum.map_join(child_results, "; ", fn dbc -> 
         "[Child #{dbc.author_id}]: #{dbc.fact_text}" 
      end)
    
    fact_text = "Intermediate Task Completed: #{state.context[:task] || "Unknown Task"}. Aggregated #{length(child_results)} sub-tasks. Summary: #{aggregated_knowledge}"
    
    # 3. Construct DBC Payload
    # We use the UpstreamMerge tool logic manually or via the actual tool module
    
    # Extract Parent ID
    imp_package = state.implementation_package || %{}
    parent_id = imp_package[:parent_node_id] || imp_package["parent_node_id"] || state.context.parent_node_id || "root"
    slot_id = state.node_id || state.context.task || "unknown_slot"
    
    # We need to construct arguments as expected by the Tool
    args = %{
      "fact_text" => fact_text,
      "slot_id" => slot_id, # This is OUR slot in the Parent
      "parent_id" => parent_id,
      "schema" => %{
         "child_count" => length(child_results),
         "child_artifacts" => child_results
      },
      "interfaces" => ["batch_result"]
    }

    Logger.info("Controller: Merging Result Upstream to Parent #{parent_id}...")

    case ACN.Tools.Lattice.UpstreamMerge.execute(args, %{node_id: state.node_id}) do
      {:ok, _dbc} ->
         Logger.info("Controller: Upstream Merge Successful.")
         
         if state.is_root do
           # Root node: DO NOT shut down - it needs to stay alive for further orchestration
           Logger.info("Controller: Root node finalization complete. Supervisor remains active for continued orchestration.")
           {:noreply, %{state | phase: :completed}}
         else
           # Non-root intermediate node: Shut down as expected
           Logger.info("Controller: Non-root node finalization complete. Requesting Shutdown.")
           Router.route({:shutdown_request}, {:local, :supervisor}, state.router)
           {:noreply, %{state | phase: :completed}}
         end
      
      {:error, reason} ->
         Logger.error("Controller: Upstream Merge Failed: #{inspect(reason)}. Retrying in 5s...")
         # Simple retry mechanism
         Process.send_after(self(), {:retry_finalize, args}, 5000)
         {:noreply, state}
    end
  end
  



  # --- Info Handlers ---

  def handle_info({:trigger_remediation, reason}, state) do
     Logger.warning("Controller: Async remediation triggered. Reason: #{reason}")
     handle_remediation(reason, state)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitored_tasks || %{}, ref) do
      nil ->
        # Not a monitored task (or already handled)
        {:noreply, state}

      task_id ->
        # Remove from monitors
        new_monitors = Map.delete(state.monitored_tasks, ref)

        if reason == :normal or reason == :shutdown do
          Logger.info("Controller: Monitor detected normal exit for child task: #{task_id} (ignoring for batch completion)")
          new_state = %{state | monitored_tasks: new_monitors}
          {:noreply, new_state}
        else
          Logger.error("Controller: CRITICAL - Child Task #{task_id} CRASHED! Reason: #{inspect(reason)}")

          # Mark as failed in batch completions
          new_completions = Map.put(state.batch_completions || %{}, task_id, :failed)

          # Trigger remediation or fail batch
          # For now, we'll log and attempt to continue, but ideally this should trigger a retry strategy
          handle_remediation("Child Task Crash: #{task_id}", %{state | monitored_tasks: new_monitors, batch_completions: new_completions})
        end
    end
  end

  @impl true
  def handle_info(:delegation_timeout, state) do
     Logger.error("Delegation Timeout! Actuator failed to respond in time.")
     if state.policy_retry_count < 10 do
        # Retry
        GenServer.cast(self(), {:internal_transition, :start_architecting})
        {:noreply, %{state | policy_retry_count: state.policy_retry_count + 1, phase: :architecting}}
     else
        Router.route({:fatal_error, "Delegation Timeout limit exceeded"}, {:local, :live_wire}, state.router)
        {:noreply, %{state | phase: :failed}}
     end
  end

  @impl true
  def handle_info(:validation_timeout, state) do
    if state.phase == :validation do
       Logger.error("TIMEOUT: Validation took too long. Assumed failed.")
       # Treat as validation failure
       Router.route({:validation_failure, %{report: "Timeout"}}, {:local, :controller}, state.router)
       {:noreply, %{state | timer_ref: nil}}
    else
       Logger.debug("Controller: Received stale validation_timeout. Ignored.")
       {:noreply, state}
    end
  end

  @impl true
  def handle_info({:retry_finalize, args}, state) do
     Logger.info("Controller: Retrying Upstream Merge...")
     case ACN.Tools.Lattice.UpstreamMerge.execute(args, %{node_id: state.node_id}) do
      {:ok, _dbc} ->
         Logger.info("Controller: Upstream Merge Successful (Retry).")
         
         # EXTRACT PARENT ID from args
         parent_id = args["parent_id"]
         
         # Check if this is the root node
         is_root = parent_id == :nonode@nohost or is_nil(parent_id) or parent_id == state.node_id
         
         if is_root do
             Logger.info("Controller: Root node finalization (Retry) complete. Supervisor remains active.")
             {:noreply, %{state | phase: :completed}}
         else
             Logger.info("Controller: Non-root node finalization (Retry) complete. Requesting Shutdown.")
             Router.route({:shutdown_request}, {:local, :supervisor}, state.router)
             {:noreply, %{state | phase: :completed}}
         end
      
      {:error, reason} ->
         Logger.error("Controller: Upstream Merge Failed Again: #{inspect(reason)}. Giving up and shutting down to avoid zombie process.")
         Router.route({:shutdown_request}, {:local, :supervisor}, state.router)
         {:noreply, %{state | phase: :failed}}
    end
  end


  # --- Private Helpers ---

  defp spawn_batch(index, state) do
    batch = Enum.at(state.batches, index)
    Logger.info("Controller: Spawning Batch #{index} (#{length(batch)} nodes)...")

    new_monitors = 
      Enum.reduce(batch, %{}, fn task, acc_monitors ->
        # Construct payload for child node
        task_id = ID.normalize(task[:id] || task["id"])
        
        # Determine path for child
        child_path = 
          case task[:path] || task["path"] do
            p when is_binary(p) -> p
            _ -> Path.join(state.working_path || "root", to_string(task_id))
          end

        spawn_payload = %{
          task: task_id,
          description: task[:description] || task["description"],
          path: child_path,
          parent_node: state.node_id || "root",
          parent_supervisor_pid: self(),
          output_slot: task_id,
          # INJECT BLUEPRINT INTO CHILD CONTEXT
          # Fix 2B: NO fallback to state.blueprint_spec. Each child receives ONLY its own
          # scoped description from the TM Planner. The previous `|| state.blueprint_spec`
          # fallback caused every sibling leaf to see the parent's full multi-file mandate,
          # so each independently invented and wrote the same files.
          blueprint_spec: task[:description] || task["description"],
          node_id: task_id,  # Unique ID for child's workspace
          # SPECIFICATION FIDELITY: Propagate specification fields
          original_specification: state.original_specification,
          specification_depth: state.specification_depth,
          specification_metadata: state.specification_metadata
        }

        # Execute Spawn SYNCHRONOUSLY
        case GenServer.call(state.router.local_directory[:supervisor], {:spawn_child, spawn_payload}, 30_000) do
          {:ok, pid} ->
            Logger.info("Controller: Child #{task_id} spawned successfully. Monitoring PID: #{inspect(pid)}")
            ref = Process.monitor(pid)
            Map.put(acc_monitors, ref, task_id)
          {:error, :spatial_violation} ->
            # RETRY PATH: The planned child path is outside the parent workspace.
            # Build descriptive feedback so handle_remediation re-runs the AI with
            # the correct bounds rather than crashing the node.
            parent_workspace = state.working_path || state.context[:path] || state.context["path"] || ""
            feedback =
              "[SPATIAL JAIL VIOLATION] Child task '#{task_id}' was assigned path '#{child_path}' " <>
              "which is OUTSIDE the parent workspace '#{parent_workspace}'. " <>
              "All child paths MUST be subdirectories of '#{parent_workspace}'. " <>
              "Re-plan this task with a corrected path that is nested inside the parent workspace."
            Logger.error("Controller: #{feedback}")
            handle_remediation(feedback, state)
            acc_monitors
          {:error, reason} ->
            Logger.error("Controller: Failed to spawn child #{task_id}: #{inspect(reason)}")
            handle_remediation("Spawn Failure: #{inspect(reason)}", state)
            acc_monitors
        end
      end)
    
    IO.inspect(new_monitors, label: "Controller: New Monitors from Batch")

    # Merge new monitors with existing ones (if any)
    updated_monitors = Map.merge(state.monitored_tasks || %{}, new_monitors)

    {:noreply, %{state | phase: :spawning, batch_completions: %{}, current_batch_index: index, monitored_tasks: updated_monitors}}
  end





  defp run_judge_validation(buffer, path, state) do
     # Judge Profile
     master_rules = ACN.Core.Governance.MasterRules.get_rules()
     vars = %{
       master_rules: master_rules,
       local_rules: state.local_rules,
       draft: buffer,
       directive: state.implementation_directive,
       deep_context: state.context,
       node_id: state.node_id
     }

     {:ok, profile} = ACN.Core.ProfileLoader.load("controller_judge", vars)
     judge_buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])

     adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
     config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"]}

     env = %{node_id: state.node_id, working_path: state.working_path || "root"}
     case ACN.AI.Pipeline.run(judge_buffer, ["submit_verdict", "upstream_merge"], config, env) do
       {:ok, msg, _, _} ->
         tool_calls = Map.get(msg, :tool_calls) || []
         Logger.info("Judge Bot generated #{length(tool_calls)} tool calls.")
         
         # 1. First Pass: Handle Commitment (upstream_merge, ingest_fact)
         resolved_dbc = 
           Enum.reduce(tool_calls, %{}, fn tc, acc_dbc ->
             case get_in(tc, ["function", "name"]) do
               "upstream_merge" ->
                 args_json = get_in(tc, ["function", "arguments"])
                 case Jason.decode(args_json) do
                    {:ok, args} ->
                       Logger.info("Bot: upstream_merge called.")
                       case ACN.Tools.Lattice.UpstreamMerge.execute(args, %{node_id: state.node_id}) do
                          {:ok, dbc_struct} -> dbc_struct
                          _ -> acc_dbc
                       end
                    _ -> acc_dbc
                 end
               _ -> acc_dbc
             end
           end)

         # 2. Second Pass: Final Verdict
         {verdict, reason, _full_args} = extract_verdict(msg)
         Logger.info("Judge Verdict: #{verdict} - Reason: #{reason}")

         if String.starts_with?(String.upcase(verdict), "APPROVED") do
           # Ensure we have the DBC from the first pass tool call (upstream_merge)
           if is_map(resolved_dbc) and Map.has_key?(resolved_dbc, :id) do
              Logger.info("Controller: Leaf Node Approved & Committed Task. Triggering Shutdown.")
              Router.route({:leaf_shutdown_signal, resolved_dbc}, {:local, :supervisor}, state.router)
              {:noreply, %{state | phase: :completed, validation_retry_count: 0}}
           else
              # 2024-03-14 Update: Rerun Judge if approved but no merge.
              if state.validation_retry_count < 1 do
                 Logger.warning("Controller: Judge APPROVED but provided NO merge data. Rerunning Judge (Retry 1/1)...")
                 GenServer.cast(self(), {:internal_transition, :run_judge_retry, buffer, path})
                 {:noreply, %{state | validation_retry_count: state.validation_retry_count + 1}}
              else
                 Logger.error("Controller: Judge APPROVED but provided NO merge data after rerun.")
                 handle_remediation("Judge approved but failed to call upstream_merge tool for commitment after rerun.", state)
              end
           end
         else
           # REJECTED: Handle remediation
           handle_remediation(reason, state)
         end

       _ -> 
         handle_remediation("AI Pipeline Failure in Judge Phase", state)
     end
  end


  defp extract_verdict(msg) do
     tool_calls = Map.get(msg, :tool_calls) || []
     
     # Search for submit_verdict in the list of tool calls
     verdict_call = Enum.find(tool_calls, fn tc -> 
       get_in(tc, ["function", "name"]) == "submit_verdict"
     end)

     case verdict_call do
       %{"function" => %{"arguments" => args_json}} ->
         case Jason.decode(args_json) do
           {:ok, args = %{"verdict" => v, "reason" => r}} -> {v, r, args}
           _ -> {msg.content, "Parsing Failure", %{}}
         end
       _ -> 
         {msg.content |> String.trim(), "No tool call", %{}}
     end
  end



  defp handle_remediation(reason, state) do
     Logger.info("Controller: Remediation required. Count: #{state.policy_retry_count}")

     directive = state.implementation_directive || %{
        task: "Unknown Task (Intermediate Node failure)",
        target_path: state.working_path || "root",
        full_context: %ACN.Infrastructure.Lattice.DeepContext{
          task: "Unknown Task (Intermediate Node failure)",
          path: state.working_path || "root"
        } |> Map.from_struct(),
        rules: []
     }

     if state.policy_retry_count < 10 do
         Logger.info("Controller: Engaging Remediation Actuator (Specialist Bot)...")
         
         # 1. Read existing file content for full context
         path = directive.target_path || "unknown"
         file_content = 
           cond do
              # Check if path is a valid file path (not a directory, not :ok, etc.)
              is_binary(path) and File.exists?(path) and File.regular?(path) ->
                case File.read(path) do
                  {:ok, content} -> content
                  {:error, reason} -> "File content not available (Read Failed: #{inspect(reason)})."
                end
              
              # If path is a directory (intermediate node case)
              is_binary(path) and File.dir?(path) ->
                "File content not available (Path is a directory - intermediate node)."
              
              # If path is not a string or doesn't exist
              true ->
                "File content not available (Invalid path or file missing: #{inspect(path)})."
            end
         
         # 2. Add Rejection Context to Directive
         new_directive = Map.merge(directive, %{
            rejection_reason: reason,
            file_content: file_content,
            node_id: state.node_id
         })

         # RE-MINT TOKEN: Ensure fresh TTL
         {:ok, new_token, _} = TokenAuthority.mint_token(
            state.private_key,
            :actuator,
            path,
            "controller",
            300
         )
 
         payload = %{
            tool: :remediate_implementation, # Use new Remediation Tool
            directive: new_directive,
            token: new_token,
            _sender: :controller
         }

         Router.route(payload, {:local, :actuator}, state.router)

         timer = Process.send_after(self(), :delegation_timeout, 600_000)
         {:noreply, %{state | policy_retry_count: state.policy_retry_count + 1, timer_ref: timer}}
     else
         Logger.error("Controller: Remediation limit reached. Triggering LiveWire.")

         local_supervisor =
            case Map.get(state.router.local_directory, :supervisor) do
               nil ->
                  case ACN.Core.NodeRegistry.lookup(state.node_id) do
                     {:ok, %{pid: pid}} -> pid
                     _ -> nil
                   end
                pid -> pid
             end

          if local_supervisor do
            lw_payload = %{
               supervisor_pid: local_supervisor,
               issue: reason,
               task: directive.task || "Unknown",
               path: directive.target_path
            }
            Router.route({:livewire_alert, lw_payload}, {:local, :live_wire}, state.router)
          else
             Logger.error("CRITICAL: Failed to find Supervisor to verify LiveWire Alert.")
          end

          {:noreply, %{state | phase: :frozen}}
      end
  end


  defp extract_blueprint_fallback(content) do
    Logger.warning("Legislator: Blueprint extraction fallback.")
    %{rules: ["Rule: Fallback due to parse error"], spec: content, path: nil, init: nil}
  end

  defp process_legislative_tools(msg, state) do
    # 1. Extract Tool Calls
    tool_calls = Map.get(msg, :tool_calls, [])
    
    # 2. Execute 'touch' calls first (Side Effects)
    Enum.each(tool_calls, fn call -> 
       case get_in(call, ["function", "name"]) do
         "touch" ->
           args_json = get_in(call, ["function", "arguments"])
           case Jason.decode(args_json) do
              {:ok, args} -> 
                  Logger.info("Controller executing [touch] from Legislator...")
                  ACN.Tools.FileSystem.Touch.execute(args, %{node_id: state.node_id, working_path: state.working_path})
              _ -> :ok
           end
         "mkdir" ->
           args_json = get_in(call, ["function", "arguments"])
           case Jason.decode(args_json) do
              {:ok, args} -> 
                  Logger.info("Controller executing [mkdir] from Legislator...")
                  ACN.Tools.FileSystem.Mkdir.execute(args, %{node_id: state.node_id, working_path: state.working_path})
              _ -> :ok
           end
         _ -> :ok
       end
    end)
    
    # 3. Extract Rules from 'submit_legislation' (Pillar II)
    rules_call = Enum.find(tool_calls, fn call -> 
       get_in(call, ["function", "name"]) == "submit_legislation"
    end)
    
    rules = 
      case rules_call do
        %{"function" => %{"arguments" => args_json}} ->
           case Jason.decode(args_json) do
             {:ok, args} -> args["rules"] || []
             _ -> []
           end
        _ -> []
      end

    # 4. Extract Blueprint from 'submit_blueprint' (Pillar I)
    blueprint_call = Enum.find(tool_calls, fn call -> 
       get_in(call, ["function", "name"]) == "submit_blueprint"
    end)
    
    case blueprint_call do
      %{"function" => %{"arguments" => args_json}} ->
         case Jason.decode(args_json) do
           {:ok, args} ->
              %{
                rules: rules,
                spec: args["technical_specifications"] || "No spec provided.",
                path: args["target_path"],
                init: args["init_command"]
              }
           _ -> extract_blueprint_fallback(msg.content) |> Map.put(:rules, rules)
         end
      _ ->
         extract_blueprint_fallback(msg.content) |> Map.put(:rules, rules)
    end
  end




  defp safe_json_decode(nil), do: {:ok, %{}}
  defp safe_json_decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> 
        Logger.error("Controller: JSON Decode Error: #{inspect(reason)}. Data: #{binary}")
        {:error, reason}
    end
  end
end
