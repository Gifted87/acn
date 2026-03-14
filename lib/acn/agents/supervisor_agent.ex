defmodule ACN.Agents.SupervisorAgent do
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Router

  alias ACN.Infrastructure.Lattice.{Lineage, DeepContext}
  alias ACN.Agents.ContextFetcher
  alias ACN.Core.ProfileLoader
  alias ACN.Core.Worksheet
  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer
  alias ACN.Core.Security.TokenAuthority
  alias ACN.Core.Utils.ID
  alias ACN.Observability.TraceContext

  defmodule State do
    defstruct [:args, :identity, :current_profile, :worksheet, :router, :parent_supervisor_pid,
               :private_key, :public_key, :lineage, :context_fetcher_pid, :local_blueprint, :is_root,
               context: %{}, children: %{}, hydration_retry_count: 0, initialized: false,
               # Issue 1 fix: deferred shutdown until all child PIDs have exited
               shutdown_pending: false]
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    node_id =
      case opts do
        map when is_map(map) -> map[:node_id] || map[:task] || map["node_id"] || map["task"]
        list when is_list(list) -> Keyword.get(list, :node_id) || Keyword.get(list, :task)
        _ -> nil
      end

    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  def get_public_context do
    # Returns the CURRENT, REAL-TIME state of this node.
    # Called by children during JIT Genesis.
    # We target the named supervisor (Genesis) if no ID passed, assuming Parent is Main.
    GenServer.call(via_tuple(nil), :get_current_state_payload)
  end

  defp via_tuple(id) do
    target_id = id || "root"
    NodeRegistry.via_tuple(:supervisor, target_id)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    node_id = 
       case opts do
         map when is_map(map) -> map[:node_id] || map[:task] || "root"
         list when is_list(list) -> Keyword.get(list, :node_id) || Keyword.get(list, :task) || "root"
         _ -> "root"
       end

    # Load Genesis Profile
    init_vars = %{
       task: "ACN Genesis (#{node_id})",
       deep_context: %DeepContext{
         path: nil,
         worksheets: %{parent: nil, grandparent: nil, great_grandparent: nil},
         acms_results: [],
         rules: %DeepContext.Rules{master: ACN.Core.Governance.MasterRules.get_rules(), ancestral: [], local: []},
         blueprint: nil,
         task: "ACN Genesis (#{node_id})"
       }
    }

    profile =
      case ProfileLoader.load("supervisor_identity", init_vars) do
        {:ok, p} -> p
        {:error, reason} -> raise "CRITICAL: Genesis Profile Missing! Reason: #{inspect(reason)}"
      end

    # 1. Start Enclave Supervisor (Isolated Sibling Tree)
    # IDEMPOTENT: Handle cases where the enclave might already be running (e.g. node reload/crash)
    _enclave_pid = 
      case start_enclave_supervisor(node_id) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        _ -> nil
      end

    # 2. Initialize Router
    router_state = %Router.State{
      agent_role: :supervisor,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    # Keymaster: Generate Ephemeral Keys for this Node
    {priv, pub} = TokenAuthority.generate_keypair()

    # 2024-01-29 Fix: Self-Kickstart. Ensure init_node runs immediately.
    # We pass opts as args. If pushed_lineage is present, it will be used.
    # CRITICAL FIX: Convert opts to MAP to prevent Access errors with string keys later.
    GenServer.cast(self(), {:init_node, Map.new(opts)})

    {:ok, %State{current_profile: profile, worksheet: Worksheet.new(), router: router_state, private_key: priv, public_key: pub, lineage: %{parent: nil, parent_id: nil, grandparent: nil, grandparent_id: nil, great_grandparent: nil, great_grandparent_id: nil}, args: %{node_id: node_id}, context: %DeepContext{}, initialized: false}}
  end

  defp start_enclave_supervisor(node_id) do
    Logger.info("SupervisorAgent: Starting Enclave Supervisor for #{node_id}...")
    ACN.Agents.EnclaveSupervisor.start_link(node_id: node_id)
  end

  # --- info ---

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    # Issue 1 fix: if we are waiting to shut down, check whether all children are gone.
    if state.shutdown_pending do
      if any_live_children?(state) do
        Logger.info("Supervisor: shutdown_pending — still waiting for live children to exit.")
        {:noreply, state}
      else
        Logger.info("Supervisor: All children exited. Executing deferred shutdown.")
        {:stop, :normal, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    # Robustness Pillar: Log agent deaths but don't crash
    Logger.error("SupervisorAgent: DETECTED CRITICAL AGENT DEATH (#PID#{inspect pid}). Reason: #{inspect reason}")
    # EnclaveSupervisor should handle the actual restart. 
    # This handler just prevents SupervisorAgent from crashing due to linked death.
    {:noreply, state}
  end

  @impl true
  def handle_info({:init_node, args}, state) do
    Logger.info("SupervisorAgent: Bootstrapping Node Identity...")
    GenServer.cast(self(), {:fetch_context, args})
    {:noreply, %{state | args: args}}
  end

  @impl true
  def handle_info({:retry_init, new_args}, state) do
     Logger.info("SupervisorAgent: Retrying init_node with updated args...")
     GenServer.cast(self(), {:init_node, new_args})
     {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("SupervisorAgent: Received UNHANDLED INFO: #{inspect(msg)}")
    {:noreply, state}
  end
  @impl true
  def handle_cast({:spawn_child, child_spec}, state) do
    # Log lineage for complete trace visibility
    ACN.Observability.AuditLogger.log_lineage(state.node_id, child_spec.id, child_spec.task)
    
    # 2024-01-29 PUSH PROTOCOL: Inject Lineage directly into child args.
    # This ensures the child doesn't need to perform a risky RPC handshake.
    pushed_lineage = %{
      parent: self(),
      grandparent: state.lineage.parent,
      great_grandparent: state.lineage.grandparent
    }
    
    enriched_spec = Map.put(child_spec, :pushed_lineage, pushed_lineage)

    ACN.Core.NodeSupervisor.start_child_node(enriched_spec)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:routed_message, _sender, payload}, state) do
    GenServer.cast(self(), payload)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:init_node, _args}, %{initialized: true} = state) do
    Logger.debug("SupervisorAgent: init_node called but already initialized. Ignoring. (Idempotency Guard)")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:init_node, args}, state) do
    # 1. Store Genesis Args
    state = %{state | args: args, parent_supervisor_pid: args[:parent_supervisor_pid], initialized: true}
    task_id = ID.normalize(args[:task] || args["task"] || "root")
    Logger.info("Supervisor Initializing Node: #{task_id}")

    # HSG: Begin trace context for this entire node process.
    # The materialized path is derived from the parent's node_id so all children
    # inherit a globally unique, rooted causal path (e.g. "root.auth.db").
    parent_node_id = args[:parent_node] || args["parent_node"]
    parent_mat_path =
      if parent_node_id && parent_node_id != "root" && parent_node_id != :root,
        do: to_string(parent_node_id),
        else: nil
    TraceContext.begin_trace(task_id, parent_mat_path)

    # RACE REDUCTION: If this task ID looks like a parallel batch child, add a tiny jitter
    # This prevents multiple nodes from hitting the same directory mkdir/stat calls simultaneously.
    if String.contains?(task_id, "_") do
       Process.sleep(:rand.uniform(100))
    end

    # 2. DEEP GENESIS: Ancestral Resolution & Context Aggregation
    parent_id = args[:parent_node] || args[:parent]
    is_root = is_nil(parent_id) or parent_id == :nonode@nohost
    
    if parent_id do
      ACN.Core.NodeRegistry.update_parent(task_id, parent_id)
    end
    
    task_desc = args[:task_description] || args["task_description"] || args[:task_desc_minimal] || "Unknown Task"
    
    # Resolve Path: Ensure it is absolute
    raw_path_arg = args[:path] || args[:output_directive] || args["path"] || args["output_directive"]
    
    # EXTRACT PATH FROM PROMPT if argument is missing
    raw_path = 
       if is_nil(raw_path_arg) or raw_path_arg == "root" do
          case Regex.run(~r/(?:in|at|path|directory|workspace)\s+([\/~][\w\-\.\/]+)/i, task_desc) do
             [_, extracted_path] -> extracted_path
             _ -> "root"
          end
       else
          raw_path_arg
       end

    path = 
      if raw_path == "root" do
        ACN.Infrastructure.Workspace.root_path() || File.cwd!()
      else
        if Path.type(raw_path) == :relative do
          Path.expand(raw_path, ACN.Infrastructure.Workspace.root_path() || File.cwd!())
        else
          raw_path
        end
      end

    Logger.info("Executing Lineage Handshake for Parent: #{inspect state.parent_supervisor_pid}")
    
    # 2024-01-29 PUSH PROTOCOL: Use pushed lineage if available.
    lineage_map = 
      if args[:pushed_lineage] do
        Logger.info("Lineage Info PUSHED from Parent. Skipping Handshake RPC.")
        args[:pushed_lineage]
      else
        # Fallback for Root or Legacy calls
        Lineage.handshake(state.parent_supervisor_pid)
      end

    # 3. Start ContextFetcher Agent
    {:ok, cf_pid} = ContextFetcher.start_link(supervisor_pid: self())
    
    Logger.info("Triggering Asynchronous Context Hydration (Pillars I-IV)...")
    
    # Prepare specification data for ContextFetcher
    spec_data = %{
      original_specification: args[:original_specification] || args["original_specification"],
      specification_depth: args[:specification_depth] || args["specification_depth"],
      specification_metadata: args[:specification_metadata] || args["specification_metadata"]
    }
    
    ContextFetcher.hydrate(cf_pid, task_desc, path, lineage_map, spec_data)

    # 4. Extract Specification Fields (for Specification Fidelity)
    original_spec = args[:original_specification] || args["original_specification"]
    current_depth = args[:specification_depth] || args["specification_depth"] || (if is_root, do: 0, else: 2)
    
    spec_metadata = args[:specification_metadata] || args["specification_metadata"] || %{
      version: "1.0",
      ingested_at: DateTime.utc_now(),
      source: "user_provided"
    }
    
    # Store specification fields in args for propagation
    updated_args = Map.merge(args, %{
      path: path,
      original_specification: original_spec,
      specification_depth: current_depth,
      specification_metadata: spec_metadata
    })
    
    # 5. Subscribe to Control Topic
    Phoenix.PubSub.subscribe(ACN.PubSub, "acn:control:#{task_id}")

    {:noreply, %{state | is_root: is_root, lineage: lineage_map, context_fetcher_pid: cf_pid, args: Map.merge(state.args, updated_args)}}
  end

  @impl true
  def handle_cast({:hydration_failed, :invalid_path, path}, state) do
    Logger.error("SupervisorAgent: Context Fetcher reported invalid path: #{inspect(path)}. Triggering retry...")
    
    if state.hydration_retry_count < 5 do
       # Retry path resolution with feedback
       new_args = Map.update(state.args, :task_description, "", fn desc -> 
         "[CRITICAL: Previous path '#{inspect(path)}' was invalid. Ensure absolute path with proper format] " <> desc 
       end)
       
       # Update path to try extraction again
       new_args = Map.put(new_args, :path, nil)
       
       Process.send_after(self(), {:retry_init, new_args}, 1000)
       {:noreply, %{state | hydration_retry_count: state.hydration_retry_count + 1}}
    else
       Logger.error("SupervisorAgent: Path validation FAILED after retries from ContextFetcher.")
       Process.exit(self(), :invalid_path_fatal)
       {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:hydration_ready, deep_context}, state) do
    # STRICTOR PATH ENFORCEMENT (High Priority)
    path = deep_context.path
    is_root = state.is_root
    workspace_root = Application.get_env(:acn, :workspace_root)
    
    is_path_valid = 
      if is_root do
        # Root node can be at the workspace root
        is_binary(path) && String.length(path) > 0
      else
        # Child nodes MUST have a sub-path (not root) and it must be absolute
        is_binary(path) && path != "root" && path != workspace_root && (String.starts_with?(path, "/") or String.starts_with?(path, "~"))
      end

    if !is_path_valid && state.hydration_retry_count < 5 do
       Logger.error("SupervisorAgent: Target Path Missing or Invalid for Child Node (Path: #{inspect(path)}). Retrying Context Gathering...")
       # Feedback: Pre-pend error to task description to nudge next attempt's path extraction
       new_args = Map.update(state.args, :task_description, "", fn desc -> "[RETRY NUDGE: Previous path resolution failed. Ensure path is absolute] " <> desc end)
       
       Process.send_after(self(), {:init_node, new_args}, 1000)
       {:noreply, %{state | hydration_retry_count: state.hydration_retry_count + 1}}
    else
      if !is_path_valid do
         Logger.error("SupervisorAgent: Target Path Enforcement FAILED after retries. System integrity at risk.")
         # Shutdown node to prevent zombie work without path
         System.stop(1) # Or some other more localized failure? 
         # Actually, just stop this supervisor.
         Process.exit(self(), :kill)
         {:noreply, state}
      else
        Logger.info("Context Hydration Complete. Path Verified: #{path}. Proceeding to Identity Determination.")
        
        task_desc = state.args[:task_description] || state.args["task_description"] || state.args[:task_desc_minimal] || "Unknown Task"

    # Determine Identity via AI (Using Full Hydrated Context)
    vars = %{
      task: task_desc,
      deep_context: deep_context
    }
    
      case ProfileLoader.load("supervisor_identity", vars) do
        {:ok, profile} ->
          Logger.info("Running Identity Determination Profile...")
          buffer = ContextBuffer.new(profile["system_prompt"])
          adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
          config = %{
            adapter: adapter, 
            stop_after_tools: true,
            opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"]
          }
          
          case Pipeline.run(buffer, ["set_node_identity"], config) do
            {:ok, msg, _final_buffer, _env} ->
              if msg.content && String.contains?(msg.content, "Error executing tool") do
                Logger.error("Identity determination failed silently (Tool Error).")
                GenServer.cast(self(), {:set_identity, "LEAF", state.args[:path]})
                {:noreply, %{state | context: deep_context}}
              else
                {:noreply, %{state | context: deep_context}}
              end

            error ->
              Logger.error("Identity Pipeline failed: #{inspect(error)}")
              GenServer.cast(self(), {:set_identity, "LEAF", state.args[:path]})
              {:noreply, %{state | context: deep_context}}
          end

      {:error, reason} ->
          Logger.error("Failed to load identity profile: #{inspect(reason)}")
          GenServer.cast(self(), {:set_identity, "LEAF", state.args[:path]})
          {:noreply, %{state | context: deep_context}}
    end
       end
     end
  end




  @impl true
  def handle_cast({:set_identity, identity, path}, state) do
    Logger.info("🎯 Identity Confirmed: #{inspect(identity)} | Path: #{inspect(path)}")
    
    # If path is provided, update args and context
    state = 
      if path do
        abs_path = 
          if Path.type(path) == :relative do
            Path.expand(path, Application.get_env(:acn, :workspace_root) || File.cwd!())
          else
            path
          end
          
        new_args = Map.put(state.args, :path, abs_path)
        new_context = %{state.context | path: abs_path}
        %{state | args: new_args, context: new_context}
      else
        state
      end
    
    # 1. Propagate identity to local agents
    local_agents = Router.discover_local_agents(state.args[:node_id])
    state = put_in(state.router.local_directory, local_agents)

    Enum.each(local_agents, fn {role, pid} -> 
      if role == :controller do
        GenServer.cast(pid, {:set_node_identity, identity, state.args[:path], state.is_root})
      else
        GenServer.cast(pid, {:set_local_identity, identity}) 
      end
    end)

    state = %{state | identity: identity}
    
    # 2. Apply Morphic State
    state = apply_morphic_state(identity, state)

    # 3. Handoff
    Logger.info("Context ready. Proceeding to Legislative Handoff.")
    GenServer.cast(self(), {:handoff})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_local_identity, _identity}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:config_update, config}, state) do
     Logger.info("Supervisor received Config Update.")
     new_args = Map.merge(state.args || %{}, config)
     {:noreply, %{state | args: new_args}}
  end
  
  @impl true
  def handle_cast({:update_local_rules, rules}, state) do
    Logger.info("Supervisor: Updating Local Rules (Pillar II).")
    new_context = put_in(state.context || %{}, [Access.key(:rules, %{}), Access.key(:local, [])], rules)
    {:noreply, %{state | context: new_context}}
  end

  @impl true
  def handle_cast({:process_wisdom_results, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:handoff}, state) do
    ctx_map = 
      case state.context do
        %DeepContext{} = dc -> Map.from_struct(dc)
        map when is_map(map) -> map
        _ -> %{}
      end

    working_path = 
      state.args[:path] || 
      state.args["path"] || 
      state.args[:output_directive] || 
      state.args["output_directive"] ||
      ctx_map[:path] ||
      ctx_map["path"] ||
      "root"

    parent_node_id = state.args[:parent_node] || state.args["parent_node"] || Node.self()

    security_token = 
      if state.identity == :leaf do
         target_path = state.args[:output_directive] || state.args["output_directive"] || "unknown"
         {:ok, token, _} = TokenAuthority.mint_token(state.private_key, :actuator, target_path)
         token
      else
         nil
      end

    payload = Map.merge(ctx_map, %{
      task_assignment: %{type: state.identity},
      genesis_args: state.args,
      security_token: security_token,
      public_key: state.public_key,
      working_path: working_path,
      parent_node_id: parent_node_id,
      node_worksheet: Worksheet.to_map(state.worksheet),
      blueprint_spec: state.args[:blueprint_spec] || state.args["blueprint_spec"],
      # Propagate specification fields
      original_specification: state.args[:original_specification],
      specification_depth: state.args[:specification_depth],
      specification_metadata: state.args[:specification_metadata]
    })

    {:ok, updated_router} = Router.route({:initialize_governance, payload}, {:local, :controller}, state.router)
    Logger.info("Handoff Complete. Data & Keys sent to Controller. Working Path: #{working_path}")
    
    node_id = state.args[:task] || state.args["task"] || "root"
    Phoenix.PubSub.broadcast(ACN.PubSub, "acn:monitor:global", {:node_startup, node_id})

    {:noreply, %{state | router: updated_router}}
  end

  @impl true
  def handle_cast({:override, :pause}, state) do
    Logger.warning("Supervisor: OVERRIDE PAUSE RECEIVED. Halting all activities.")
    apply_morphic_state(:halt, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:override, :restart}, state) do
    Logger.warning("Supervisor: OVERRIDE RESTART RECEIVED. Re-initializing Node...")
    GenServer.cast(self(), {:init_node, state.args})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:leaf_shutdown_signal, dbc}, state) do
    Logger.info("Supervisor: LF Shutdown Signal received. DBC: #{inspect dbc}")

    child_id = 
      dbc.provenance_data[:node] || 
      dbc.author_id || 
      state.args[:task] ||
      "unknown_child"
    
    updated_children = Map.update(state.children, child_id, 
      %{status: :completed, dbc: dbc},
      fn existing -> %{existing | status: :completed, dbc: dbc} end
    )
    
    total_children = map_size(updated_children)
    completed_count = Enum.count(updated_children, fn {_id, child} -> child.status == :completed end)
    all_complete? = total_children > 0 and completed_count == total_children
    
    parent_id = state.args[:parent_node] || state.args["parent_node"]
    is_root? = is_nil(parent_id) or parent_id == :root or parent_id == "root"
    
    cond do
      is_root? and total_children == 0 ->
        Logger.info("GENESIS COMPLETE: Root Leaf Node execution finished successfully.")
        {:noreply, %{state | identity: :completed, children: updated_children}}
      
      is_root? and all_complete? ->
        Logger.info("GENESIS COMPLETE: All #{total_children} children finished successfully.")
        {:noreply, %{state | identity: :completed, children: updated_children}}
      
      is_root? ->
        {:noreply, %{state | children: updated_children}}
      
      all_complete? and total_children > 0 and state.identity == :leaf ->
        Logger.info("Supervisor: All #{total_children} children completed (Leaf/Independent). Terminating Node #{state.args[:task]}...")
        {:stop, :normal, %{state | children: updated_children}}
      
      total_children > 0 ->
        {:noreply, %{state | children: updated_children}}
      
      true ->
        Logger.warning("Supervisor: Received Leaf Shutdown Signal but conditions for termination not met (Children: #{total_children}, Identity: #{state.identity}). Ignoring.")
        {:noreply, %{state | children: updated_children}}
    end
  end

  @impl true
  def handle_cast({:lattice_merge, slot_id, data}, state) do
    Logger.info("SupervisorAgent: Received Lattice Merge for slot #{slot_id}. Proxying to Actuator.")
    Router.route({:lattice_merge, slot_id, data}, {:local, :actuator}, state.router)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:child_completed, _child_role, slot_id, dbc}, state) do
    Logger.info("SupervisorAgent: Upstream Merge received from child for slot: #{slot_id}")
    Router.route({:lattice_merge, slot_id, dbc}, {:local, :actuator}, state.router)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:receive_child_artifact, slot_id, artifact, child_id}, state) do
    new_state = commit_artifact(slot_id, artifact, child_id, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_local_blueprint, blueprint}, state) do
    Logger.info("Supervisor: Received Local Blueprint Update (Pillar I Sync).")
    new_state = %{state | local_blueprint: blueprint}
    updated_context = 
      if is_struct(state.context, DeepContext) do
        %{state.context | blueprint: blueprint}
      else
        state.context
      end
    {:noreply, %{new_state | context: updated_context}}
  end

  @impl true
  def handle_cast({:shutdown_request}, state) do
    # Issue 1 fix: Do NOT stop immediately. The parent must outlive all children.
    # A child that is still bootstrapping (init_node → Lineage.handshake) will
    # crash if the parent exits beneath it. Instead, set shutdown_pending: true
    # and only stop once every tracked child PID has exited naturally.
    
    if !any_live_children?(state) do
      Logger.info("Supervisor: No live children remaining. Shutting down now.")
      {:stop, :normal, state}
    else
      Logger.info("Supervisor: shutdown_request received but children still alive. Deferring stop.")
      {:noreply, %{state | shutdown_pending: true}}
    end
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.warning("Supervisor: Received UNHANDLED CAST: #{inspect(msg)}")
    {:noreply, state}
  end


  # --- Calls ---

  @impl true
  def handle_call({:spawn_child, task}, _from, state) do
    task_id = ID.normalize(task["id"] || task[:id] || task["name"] || task[:task] || task["task"] || task["node_id"] || task[:node_id])
    Logger.info("SupervisorAgent: Spawning child for task #{task_id}")
    
    # Use the already-normalized task_id for output_slot to prevent ID mismatch
    output_slot = task_id
    
    Logger.info("SupervisorAgent: Spawning child for task #{task_id}. Task data: #{inspect(task)}")
    child_raw_path = task["path"] || task[:path]
    Logger.info("SupervisorAgent: child_raw_path = #{inspect(child_raw_path)}")
    
    child_path = 
      if is_nil(child_raw_path) do
        parent_path = state.args[:path] || Application.get_env(:acn, :workspace_root) || File.cwd!()
        
        # RECURSION TRAP DETECTION: 
        # If task_id is already a significant segment of parent_path, do not append it.
        # This prevents paths like /.../auth/auth/auth/auth
        path_segments = Path.split(parent_path)
        if task_id in path_segments do
          Logger.warning("SupervisorAgent: Recursion Trap Detected for #{task_id}. Reuse parent path.")
          parent_path
        else
          Path.join(parent_path, to_string(task_id))
        end
      else
        if Path.type(child_raw_path) == :relative do
          Path.expand(child_raw_path, state.args[:path] || File.cwd!())
        else
          child_raw_path
        end
      end

    # Fix 4B: Spatial Containment (Spawn Guard)
    # The child's workspace MUST be a subdirectory or equal to the parent's workspace.
    parent_workspace = state.args[:path] || ""
    is_path_valid = parent_workspace == "" or String.starts_with?(child_path, parent_workspace)
    
    if not is_path_valid do
      Logger.error("SupervisorAgent: SPATIAL VIOLATION REJECTED. Child path #{child_path} is outside parent bounds #{parent_workspace}")
      {:reply, {:error, :spatial_violation}, state}
    else
      # Fix 2A: Removed File.mkdir_p!(child_path) — the Intermediate Legislator
      # is the sole owner of directory creation via its mkdir tool call.
      # Pre-creating the directory here caused every intermediate node's workspace
      # to be created twice.


      if is_nil(task_id) do
      Logger.error("SupervisorAgent: CRITICAL - Cannot spawn child with nil task ID!")
      {:reply, {:error, :invalid_task_id}, state}
    else
      child_args = %{
         task: task_id, 
         path: child_path,
         parent_node: state.args[:task] || "root", 
         output_slot: output_slot,
         task_desc_minimal: task["description"] || task[:description],
         ancestral_worksheet: state.worksheet,
         parent_supervisor_pid: self(),
         node_id: task_id,
         blueprint_spec: task[:blueprint_spec] || task["blueprint_spec"]
      }
      
      # SPECIFICATION FIDELITY: Propagate original_specification to ALL depths.
      # Removing the depth <= 3 cliff was a critical fix: deep nodes (depth 4+) were
      # losing the original spec, causing language/framework hallucinations.
      current_depth = state.args[:specification_depth] || 0
      child_depth = if current_depth == 0, do: 2, else: current_depth + 1

      original_spec = state.args[:original_specification]
      spec_metadata = state.args[:specification_metadata]

      Logger.info("SupervisorAgent: Passing full original specification to child at depth #{child_depth}")

      child_args = Map.merge(child_args, %{
        original_specification: original_spec,
        specification_depth: child_depth,
        specification_metadata: spec_metadata
      })

      # Fix 1A: Build and inject pushed_lineage so the child SupervisorAgent can
      # skip the Lineage.handshake() RPC entirely. Without this, every child
      # spawned via handle_call(:spawn_child) fell through to the fallback RPC,
      # which crashed when the parent exited before the child completed the call.
      pushed_lineage = %{
        parent: self(),
        parent_id: state.args[:node_id] || state.args["node_id"],
        grandparent: state.lineage[:parent],
        grandparent_id: state.lineage[:parent_id],
        great_grandparent: state.lineage[:grandparent],
        great_grandparent_id: state.lineage[:grandparent_id]
      }

      child_args = Map.put(child_args, :pushed_lineage, pushed_lineage)

      case ACN.Core.NodeSupervisor.start_child_node(child_args) do
        {:ok, child_pid} ->
           Logger.info("Child Node Spawned: #{inspect(child_pid)}")
           Process.monitor(child_pid)
           GenServer.cast(child_pid, {:init_node, child_args})
           new_children = Map.put(state.children, task_id, %{status: :running, dbc: nil, pid: child_pid})
           {:reply, {:ok, child_pid}, %{state | children: new_children}}

        {:error, {:already_started, child_pid}} ->
           if Process.alive?(child_pid) do
              Logger.info("Child Node #{inspect(task_id)} already active at #{inspect(child_pid)}. Re-initializing (Idempotent).")
              # Also inject pushed_lineage on re-init
              GenServer.cast(child_pid, {:init_node, child_args})
              new_children = Map.put(state.children, task_id, %{status: :running, dbc: nil, pid: child_pid})
              {:reply, {:ok, child_pid}, %{state | children: new_children}}
           else
              Logger.warning("Child Node #{inspect(task_id)} exists in registry but is DEAD (#PID#{inspect child_pid}). Retrying spawn...")
              # Registry cleanup is async, so we wait a bit or try to force it
              # For now, we return error so the Controller can retry or remediate
              {:reply, {:error, :ghost_process_detected}, state}
           end

        {:error, reason} ->
           Logger.error("Failed to spawn child node: #{inspect(reason)}")
           {:reply, {:error, reason}, state}
      end
    end
    end # Closes "if not is_path_valid do ... else ..."
  end

  @impl true
  def handle_call(:get_current_state_payload, _from, state) do
     payload = %{
        rules: state.context[:rules] || [],
        ancestral_memory: Worksheet.to_map(state.worksheet), 
        origin: node(),
        gm_memories: state.context[:gm_memories],
        blueprint_spec: state.args[:blueprint_spec] || state.args["blueprint_spec"]
     }
     {:reply, {:ok, payload}, state}
  end

  @impl true
  def handle_call(:get_lineage, _from, state) do
    reply = %{
      parent_pid: self(),
      parent_id: state.args[:node_id] || state.args["node_id"],
      grandparent_pid: state.lineage[:parent],
      grandparent_id: state.lineage[:parent_id],
      great_grandparent_pid: state.lineage[:grandparent],
      great_grandparent_id: state.lineage[:grandparent_id]
    }
    
    # NEW: Race Condition Fix. The child has now successfully completed its initialization
    # handshake. We notify the Controller so it knows this child is "ready" and won't
    # prematurely shut down the enclave if the batch finishes too quickly.
    Router.route({:child_handshake_complete}, {:local, :controller}, state.router)
    
    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_call(:get_rules, _from, state) do
    local_rules = get_in(state.context, [Access.key(:rules, %{}), Access.key(:local, [])]) || []
    {:reply, {:ok, local_rules}, state}
  end

  @impl true
  def handle_call(:get_worksheet, _from, state) do
    {:reply, {:ok, Worksheet.to_map(state.worksheet)}, state}
  end

  @impl true
  def handle_call(:get_blueprint, _from, state) do
    blueprint = state.local_blueprint || (if is_struct(state.context), do: state.context.blueprint, else: nil) || "No blueprint available."
    {:reply, {:ok, blueprint}, state}
  end

  @impl true
  def handle_call(:get_parent_id, _from, state) do
    parent_id = state.args[:parent_node]
    {:reply, {:ok, parent_id}, state}
  end

  @impl true
  def handle_call(:get_uplink, _from, state) do
    {:reply, {:ok, state.parent_supervisor_pid}, state}
  end

  @impl true
  def handle_call(:get_identity, _from, state) do
    identity = state.identity || :leaf
    {:reply, {:ok, identity}, state}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, {:ok, state.context}, state}
  end

  @impl true
  def handle_call(:get_node_id, _from, state) do
    node_id = state.args[:node_id] || state.args[:task] || state.args["task"] || "root"
    {:reply, node_id, state}
  end

  @impl true
  def handle_call(:get_output_slot, _from, state) do
    slot = state.args[:output_slot] || state.args["output_slot"]
    {:reply, {:ok, slot}, state}
  end

  @impl true
  def handle_call({:inject_node_sheet, slot_id, data}, _from, state) do
    Logger.info("SupervisorAgent: Injecting data into NodeSheet slot: #{slot_id}")
    new_worksheet = Worksheet.put(state.worksheet, slot_id, data, :artifact)
    new_state = %{state | worksheet: new_worksheet}
    Router.route({:task_complete, slot_id}, {:local, :controller}, state.router)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_child_results, _from, state) do
    child_dbcs = 
      state.worksheet
      |> Worksheet.to_map()
      |> Enum.filter(fn {_key, slot} ->
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
    new_state = commit_artifact(slot_id, artifact, child_id, state)
    if new_state == state do
       {:reply, {:error, :unauthorized}, state}
    else
       {:reply, :ok, new_state}
    end
  end

  # --- Private Helpers ---

  defp commit_artifact(slot_id, artifact, child_id, state) do
    slot_id = ID.normalize(slot_id)
    child_id = ID.normalize(child_id)
    Logger.info("Supervisor committing artifact for Slot: #{slot_id} from Child: #{child_id}")

    if slot_id == child_id do
      # Check if this slot already exists (prevents duplicate ingestion)
      existing_slot = Worksheet.get(state.worksheet, slot_id)
      is_new_artifact = is_nil(existing_slot)
      
      new_worksheet = Worksheet.put(state.worksheet, slot_id, artifact, :artifact)
      
      # Persist to disk (path is in args)
      working_path = state.args[:path] || state.args["path"]
      Worksheet.save(new_worksheet, working_path)
      
      # Ingest to ACMS ONLY if this is a new artifact (prevent duplicates from retries)
      if is_new_artifact do
        Task.start(fn ->
          ACN.Infrastructure.MemoryClient.ingest(artifact)
        end)
      else
        Logger.debug("Supervisor: Artifact #{slot_id} already committed. Skipping duplicate ACMS ingestion.")
      end
      
      Router.route({:task_complete, child_id}, {:local, :controller}, state.router)
      %{state | worksheet: new_worksheet}
    else
      Logger.warning("Security Alert: Child #{child_id} tried to write to unauthorized slot #{slot_id}")
      state
    end
  end

  defp apply_morphic_state(identity, state) do
    case identity do
      :leaf ->
        Logger.info("[Morphic] Mode: LEAF. Sleeping TaskManager.")
        case Router.route({:sleep}, {:local, :task_manager}, state.router) do
          {:ok, s1} -> %{state | router: s1}
          _ -> state
        end
        
      :intermediate ->
        Logger.info("[Morphic] Mode: INTERMEDIATE. Waking TaskManager.")
        with {:ok, s1} <- Router.route({:sleep}, {:local, :actuator}, state.router),
             {:ok, s2} <- Router.route({:wake}, {:local, :task_manager}, s1) do
          %{state | router: s2}
        else
          {:error, reason} -> 
             Logger.error("[Morphic] CRITICAL: Failed to configure INTERMEDIATE mode. Missing agents? Reason: #{inspect(reason)}")
             raise "Morphic State Failure: Required agent not found for :intermediate mode. (Reason: #{inspect(reason)})"
        end
        
      :halt ->
        Logger.info("[Morphic] Mode: HALT. Sleeping all agents.")
        s1 = 
          case Router.route({:sleep}, {:local, :task_manager}, state.router) do
             {:ok, s} -> s
             _ -> state.router
          end
        s2 = 
          case Router.route({:sleep}, {:local, :controller}, s1) do
             {:ok, s} -> s
             _ -> s1
          end
        %{state | router: s2}
        
      _ ->
        Logger.warning("[Morphic] Unknown Identity.")
        state
    end
  end

  defp any_live_children?(state) do
    # 1. Check local PIDs we've tracked
    pid_check = Enum.any?(state.children || %{}, fn {_id, %{pid: pid}} -> Process.alive?(pid) end)
    
    if pid_check do
      true
    else
      # 2. Safety Check: If PIDs died, verify in Registry that they haven't been restarted
      # with a new PID that we haven't linked to yet.
      Enum.any?(state.children || %{}, fn {id, _} -> 
        case ACN.Core.NodeRegistry.lookup(id) do
          {:ok, %{pid: pid}} -> Process.alive?(pid)
          _ -> false
        end
      end)
    end
  end
end
