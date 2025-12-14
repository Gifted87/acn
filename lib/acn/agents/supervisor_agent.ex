defmodule ACN.Agents.SupervisorAgent do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router
  alias ACN.Infrastructure.Lattice
  alias ACN.Core.ProfileLoader
  alias ACN.Core.Worksheet
  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer

  defmodule State do
    defstruct [:args, :identity, :current_profile, :worksheet, context: %{}]
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    # ID defaults to nil, handling root case

    # We should normalize opts/args
    # If it's a list, keyword list. If map, map.
    node_id =
      case opts do
        map when is_map(map) -> map[:task]
        list when is_list(list) -> Keyword.get(list, :node_id)
        _ -> nil
      end

    GenServer.start_link(__MODULE__, [], name: via_tuple(node_id))
  end

  def get_public_context do
    # Returns the CURRENT, REAL-TIME state of this node.
    # Called by children during JIT Genesis.
    # We target the named supervisor (Genesis) if no ID passed, assuming Parent is Main.
    # Logic: Parent Node (Erlang Node) -> Main Supervisor (:supervisor registered name via Registry?)
    # Registry registers {:supervisor, :supervisor} or {:supervisor, "task_id"}.
    # If the parent is the Root Supervisor, its ID is nil or :supervisor.
    # We try to call the name registered via via_tuple(nil).
    
    GenServer.call(via_tuple(nil), :get_current_state_payload)
  end

  defp via_tuple(id) do
    target_id = id || :supervisor
    NodeRegistry.via_tuple(:supervisor, target_id)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    # Load Genesis Profile
    profile =
      case ProfileLoader.load("supervisor_identity", %{task: "ACN Genesis (Root)"}) do
        {:ok, p} -> p
        {:error, reason} -> raise "CRITICAL: Genesis Profile Missing! Reason: #{inspect(reason)}"
      end

    {:ok, %State{current_profile: profile, worksheet: Worksheet.new()}}
  end

  @impl true
  def handle_cast({:init_node, args}, state) do
    # 1. Store Genesis Args (Critical for Downstream)
    state = %{state | args: args}

    Logger.info("Supervisor Initializing Node: #{args[:task_id] || "Unknown"}")

    # 2. JIT GENESIS: Ancestral Fetch (The Lattice Link)
    # This MUST happen before Identity, so we have fresh context.
    parent_node = args[:parent_node] # This is now the Erlang Node Atom
    
    # Wait, JIT means we fetch the *Latest* data.
    context =
      case Lattice.fetch_ancestral_data(parent_node) do
        {:ok, remote_data} ->
          Logger.info("Connected to Parent (#{inspect(parent_node)}). JIT Hydration Complete.")
          remote_data
        {:error, reason} ->
          Logger.info("Orphan Node / Root Genesis. Reason: #{inspect(reason)}. Loading Default Context.")
          %{rules: [], origin: :genesis, gm_memories: []}
      end

    state_with_context = %{state | context: context}

    # 3. Determine Identity via AI
    # Load Supervisor Identity Profile
    # Use minimal descriptor if available, or fetch full task from context?
    # Context usually holds 'task_description' for THIS node? No, context holds PARENT's state.
    # The 'task' description for THIS node was passed in args as :task_desc_minimal
    
    task_desc = args[:task_desc_minimal] || args[:task] || "Unknown Task"
    
    case ProfileLoader.load("supervisor_identity", %{task: task_desc}) do
      {:ok, profile} ->
          Logger.info("Running Identity Determination Profile...")
          buffer = ContextBuffer.new(profile["system_prompt"])
          config = %{adapter: ACN.AI.Adapters.OpenAI}
          Pipeline.run(buffer, ["set_node_identity"], config)
          
      {:error, reason} ->
          Logger.error("Failed to load identity profile: #{inspect(reason)}. Fallback via heuristics.")
          # Fallback
          identity = if args[:task_type] == :manager, do: :intermediate, else: :leaf
          GenServer.cast(self(), {:set_identity, identity})
    end

    {:noreply, state_with_context}
  end

  # Callback from Tool
  @impl true
  def handle_cast({:set_identity, identity}, state) do
    Logger.info("Identity Confirmed: #{inspect(identity)}")
    
    state = %{state | identity: identity}
    
    # 3. Apply Morphic State (Gap Fix)
    apply_morphic_state(identity)

    # 4. Transition to Wisdom Phase (Gap C Remediation)
    Logger.info("Transitioning to Wisdom Seek Phase.")
    GenServer.cast(self(), {:process_wisdom_results, state.args[:task] || "Unknown"})

    {:noreply, state}
  end
  
  defp apply_morphic_state(identity) do
    # Wake specialized agents based on role
    case identity do
      :leaf ->
        Logger.info("[Morphic] Mode: LEAF. Waking Specialist; Sleeping TaskManager.")
        Router.route({:wake}, {:local, :specialist})
        Router.route({:sleep}, {:local, :task_manager})
        
      :intermediate ->
        Logger.info("[Morphic] Mode: INTERMEDIATE. Waking TaskManager; Sleeping Specialist.")
        Router.route({:wake}, {:local, :task_manager})
        Router.route({:sleep}, {:local, :specialist})
        
      _ ->
        Logger.warning("[Morphic] Unknown Identity.")
    end
  end

  @impl true
  def handle_cast({:config_update, config}, state) do
     Logger.info("Supervisor received Config Update.")
     # Update args or context dynamically
     # Merging config into args for now
     new_args = Map.merge(state.args || %{}, config)
     {:noreply, %{state | args: new_args}}
  end

  
  @impl true
  def handle_cast({:process_wisdom_results, task_desc}, state) do
     # Run the pipeline here to avoid blocking init (though cast is async anyway)
     
     # Load Profile
     profile_res = ProfileLoader.load("supervisor_wisdom", %{task: task_desc})
     
     wisdom_text = 
       case profile_res do
         {:ok, profile} ->
           buffer = ContextBuffer.new(profile["system_prompt"])
           config = %{adapter: ACN.AI.Adapters.OpenAI}
           allowed_tools = profile["allowed_tools"]
           
           case Pipeline.run(buffer, allowed_tools, config) do
              {:ok, _msg, final_buffer} ->
                 # Extract Tool Outputs
                 # ContextBuffer.to_list(final_buffer) -> list of maps
                 # Look for role: "tool"
                 final_buffer.history
                 |> Enum.filter(fn m -> m.role == "tool" end)
                 |> Enum.map(fn m -> m.content end)
                 |> Enum.join("\n\n")
                 
              _ -> ""
           end
         _ -> ""
       end
       
     # Update Context
     # If empty, default.
     final_wisdom = if wisdom_text == "", do: "No historical wisdom available.", else: wisdom_text
     
     new_context = Map.put(state.context, :gm_memories, final_wisdom)
     
     # Proceed to Handoff
     GenServer.cast(self(), {:handoff})
     
     {:noreply, %{state | context: new_context}}
  end

  @impl true
  def handle_cast({:handoff}, state) do
    # Pass critical directives downstream
    # 5-Source Data Aggregation (Legislator Phase Step 1.1)
    
    # 1. Master Rules (Priority 0)
    master_rules = ACN.Core.Governance.MasterRules.get_rules()

    # 2. Ancestral Rules (Priority 1) -> Already in state.context[:rules] or empty
    ancestral_rules = state.context[:rules] || []

    # 3. Task Requirements (Priority 2)
    task_desc = state.args[:task] || state.args["task"] || "Unknown"

    # 4. Output Directive (Priority 2)
    output_directive = state.args[:output_directive] || state.args["output_directive"] || "None"

    # 5. Associative Wisdom (Priority 3) -> Already in state.context[:gm_memories]
    wisdom_warnings = state.context[:gm_memories] || "No wisdom available."
    
    payload = %{
      task_assignment: %{type: state.identity},
      
      # We construct the " Legislator Context" here?
      # Or we pass raw data and let Controller construct it?
      # The Controller expects 'governance_data' or we just enrich 'context'.
      
      governance_data: %{
         master_rules: master_rules,
         ancestral_rules: ancestral_rules,
         task_description: task_desc,
         output_directive: output_directive,
         wisdom_warnings: wisdom_warnings
      },

      context: state.context, # Backwards compat
      genesis_args: state.args,
      output_directive: output_directive,
      parent_address: state.args[:parent_Node_Worksheet_addr] || state.args["parent_Node_Worksheet_addr"]
    }

    Router.route({:initialize_governance, payload}, {:local, :controller})
    Logger.info("Handoff Complete. Data Aggregated.")

    {:noreply, state}
  end
  

  # Only for test/verification handling shutdown requests from Synthesizer or others routed here
  @impl true
  def handle_cast({:shutdown_request}, state) do
    Logger.warning("Supervisor received shutdown request. (Not implemented in this phase)")
    {:noreply, state}
  end



  @impl true
  def handle_cast({:spawn_child, task}, state) do
    Logger.info("Supervisor received spawn request for Node: #{task.id} (#{task.description})")

    # JIT GENESIS: PREVENT STALE CONTEXT
    # We do NOT pass 'state.context' or 'worksheet' here.
    # We only pass the POINTER to the parent (us).
    
    output_slot = task[:merge_slot_id] || task["merge_slot_id"] || task.id
    
    child_args = %{
       task: task.id, 
       task_type: :leaf, 
       
       # Lattice Pointer
       parent_node: Node.self(), 
       
       output_slot: output_slot,
       
       # Minimal Task Info (for Identity Profile)
       # The rest comes from JIT fetch
       task_desc_minimal: task.description || task["description"]
    }

    # Execute Spawn
    case ACN.Core.NodeSupervisor.start_child_node(child_args) do
      {:ok, child_pid} ->
         Logger.info("Child Node Spawned: #{inspect(child_pid)}")
         # Initialize the Child. 
         # Note: Child will call Lattice.fetch_ancestral_data(parent_node) in its init_node.
         GenServer.cast(child_pid, {:init_node, child_args})

      {:error, reason} ->
         Logger.error("Failed to spawn child node: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:receive_child_artifact, slot_id, artifact, child_id}, state) do
    Logger.info("Supervisor received artifact for Slot: #{slot_id} from Child: #{child_id}")

    if slot_id == child_id do
      # Update Worksheet
      new_worksheet = Worksheet.put(state.worksheet, slot_id, artifact, :artifact)
      state = %{state | worksheet: new_worksheet}

      # Notify Controller
      Router.route({:task_complete, child_id}, {:local, :controller})

      {:noreply, state}
    else
      Logger.warning("Security Alert: Child #{child_id} tried to write to unauthorized slot #{slot_id}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_current_state_payload, _from, state) do
     # Construct the public context payload
     payload = %{
        rules: state.context[:rules] || [],
        
        # Flattened Artifacts (JIT Hydration)
        ancestral_memory: Worksheet.to_map(state.worksheet), 
        
        origin: node(),
        gm_memories: state.context[:gm_memories]
     }
     {:reply, {:ok, payload}, state}
  end
  
  @impl true
  def handle_call(:get_parent_id, _from, state) do
    # Parent ID is in args[:parent_node]
    parent_id = state.args[:parent_node]
    {:reply, {:ok, parent_id}, state}
  end

  @impl true
  def handle_call(:get_identity, _from, state) do
    # Return current identity (:leaf or :intermediate)
    identity = state.identity || :leaf
    {:reply, {:ok, identity}, state}
  end

  @impl true
  def handle_call(:get_child_results, _from, state) do
    # Extract DBCs from worksheet slots
    # Worksheet slots contain artifacts with metadata
    # We iterate and collect any DBC structures
    child_dbcs = 
      state.worksheet
      |> Worksheet.to_map()
      |> Enum.filter(fn {_key, slot} ->
        # Check if slot is a DBC (has required fields)
        is_map(slot) and Map.has_key?(slot, :artifact_hash) and Map.has_key?(slot, :fact_text)
      end)
      |> Enum.map(fn {_key, dbc} -> dbc end)
    
    {:reply, {:ok, child_dbcs}, state}
  end

  @impl true
  def handle_call({:read_worksheet, key}, _from, state) do
    case Worksheet.get(state.worksheet, key) do
      nil -> {:reply, {:error, :not_found}, state}
      slot -> {:reply, {:ok, slot}, state}
    end
  end
  @impl true
  def handle_call({:receive_child_artifact, slot_id, artifact, child_id}, _from, state) do
    Logger.info("Supervisor received artifact (SYNC) for Slot: #{slot_id} from Child: #{child_id}")

    if slot_id == child_id do
      # Update Worksheet
      new_worksheet = Worksheet.put(state.worksheet, slot_id, artifact, :artifact)
      state = %{state | worksheet: new_worksheet}

      # Notify Controller
      Router.route({:task_complete, child_id}, {:local, :controller})

      {:reply, :ok, state}
    else
      Logger.warning("Security Alert: Child #{child_id} tried to write to unauthorized slot #{slot_id}")
      {:reply, {:error, :unauthorized}, state}
    end
  end
end
