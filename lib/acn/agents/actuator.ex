defmodule ACN.Agents.Actuator do
  use GenServer, restart: :transient
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Router
  alias ACN.Core.Security.TokenAuthority
  alias ACN.Agents.Actuator.Sandbox
  alias ACN.Core.ProfileLoader
  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer
  alias ACN.Observability.Emitter

  # Define Telemetry Events
  # [:acn, :actuator, :file_write]
  # [:acn, :actuator, :exec]
  # [:acn, :security, :token_rejection]

  # --- Public API ---

  def start_link(opts) do
    node_id = opts[:node_id] || "root"
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  defp via_tuple(node_id) do
    NodeRegistry.via_tuple(:actuator, "#{node_id}_actuator")
  end
  # end removed

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    node_id = opts[:node_id] || "root"
    # Try to extract key from opts if provided (e.g. testing)
    public_key = Keyword.get(opts, :public_key)

    # Initialize Router
    router_state = %Router.State{
      agent_role: :actuator,
      node_id: node_id,
      local_directory: Router.discover_local_agents(node_id)
    }

    # Attempt immediate sync if key not provided in opts
    initial_key = public_key || fetch_key_synchronously(node_id)

    # Schedule standard refresh cycle
    send(self(), :refresh_key)

    state = %{
      public_key: initial_key, 
      router: router_state,
      node_id: node_id,
      pending_work: %{} # tracks lifecycle state
    }

    {:ok, state}
  end

  defp fetch_key_synchronously(node_id) do
    # Try to find Controller
    target_id = "#{node_id}_controller"
    case NodeRegistry.lookup(target_id) do
      {:ok, %{metadata: %{public_key: pk}}} when is_binary(pk) -> pk
      {:ok, %{pid: pid}} ->
        try do
          # Direct call fallback
          GenServer.call(pid, :get_public_key, 2000)
        catch
          _, _ -> nil
        end
      _ -> nil
    end
  end


  @impl true
  def handle_info(:refresh_key, state) do
    target_id = "#{state.node_id}_controller"
    key =
      case NodeRegistry.lookup(target_id) do
        {:ok, %{metadata: %{public_key: pk}}} when is_binary(pk) -> pk
        {:ok, %{pid: pid}} ->
          # Fallback: Ask Controller directly if metadata invalid (legacy)
          try do
             GenServer.call(pid, :get_public_key)
          catch
             _, _ -> nil
          end
        _ -> nil
      end

    if key do
      Logger.info("Actuator (node #{state.node_id}) synced Security Key.")
      # Refresh every hour
      Process.send_after(self(), :refresh_key, 3_600_000)
      {:noreply, %{state | public_key: key}}
    else
      # Retry soon
      Process.send_after(self(), :refresh_key, 1_000)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:set_local_identity, _identity}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sleep}, state) do
    # No-op: Likely a heartbeat or pause signal from Supervisor
    {:noreply, state}
  end



  @impl true
  def handle_cast({:merge_artifacts, batch_id, token}, state) do
    # Security Check
    # We construct a mock payload to reuse validate_access!
    # OR we verify manually here since it's a special message.
    # Resource is target path (e.g. merged_batch_X.ex)
    target_path = "merged_batch_#{batch_id}.ex" 
    
    # We verify if token has :actuator scope
    case TokenAuthority.verify(token, state.public_key, :actuator, target_path) do
       {:ok, _claims} ->
           Logger.info("Actuator Merging Artifacts for Batch #{batch_id}...")
           
           # SIMULATION: Create the file to satisfy Validator
           ACN.Infrastructure.Workspace.write_atomic("root", target_path, "# Merged Content for Batch #{batch_id}")
           
           # Notify Controller
           Router.route({:merge_success, batch_id}, {:local, :controller}, state.router)
           
       {:error, reason} ->
           Logger.error("Action Denied (Merge): #{inspect(reason)}")
           Router.route({:action_failure, "Merge Denied"}, {:local, :controller}, state.router)
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:lattice_merge, slot_id, data}, state) do
    # Handle legacy 3-tuple (likely from Supervisor)
    handle_lattice_merge(slot_id, data, state)
  end

  @impl true
  def handle_cast({:lattice_merge, slot_id, data, _token}, state) do
    # Handle security-enriched 4-tuple
    handle_lattice_merge(slot_id, data, state)
  end

  @impl true
  def handle_cast({:routed_message, sender, payload}, state) do
    # Dispatch based on payload structure to avoid double-wrapping
    case payload do
      {:perform_action, map} when is_map(map) ->
        # Already wrapped, just inject sender
        GenServer.cast(self(), {:perform_action, Map.put(map, :_sender, sender)})
      
      map when is_map(map) ->
        # Raw map, wrap and inject sender (legacy/simplified flow)
        GenServer.cast(self(), {:perform_action, Map.put(map, :_sender, sender)})
        
      other ->
        # Generic message (e.g. :lattice_merge), pass through
        GenServer.cast(self(), other)
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:perform_action, payload}, state) do
    # Gatekeeper Interceptor
    case validate_access!(payload, state) do
      {:ok, _claims} ->
        # Authorized
        sender = payload[:_sender] || :controller
        execute_tool(payload, sender, state)
 
      {:error, reason} ->
        Logger.error("SECURITY ALERT: UNAUTHORIZED ACCESS ATTEMPT. Reason: #{inspect(reason)}")
        :telemetry.execute([:acn, :security, :token_rejection], %{count: 1}, %{reason: reason})
        # Emit pain signal
        Router.route({:pain_signal, 10}, {:local, :live_wire}, state.router)
        
        # NOTIFY SENDER OF FAILURE so they don't hang
        sender = payload[:_sender] || :controller
        Router.route({:action_failure, "Security Check Failed: #{inspect(reason)}"}, {:local, sender}, state.router)
        
        {:noreply, state}
    end
  end



  defp handle_lattice_merge(slot_id, data, state) do
    Logger.info("Actuator: Performing Physical Merge for slot #{slot_id}")
    
    # Verify slot and Inject into NodeSheet
    # (Since Actuator is Local to SupervisorAgent in this node)
    case GenServer.call(NodeRegistry.via_tuple(:supervisor, :supervisor), {:inject_node_sheet, slot_id, data}) do
      :ok ->
        Logger.info("Actuator: Merge Successful. Triggering event.")
        # Trigger Event: {:node_sheet_updated, slot_id}
        # Broadcast to Nervous System
        Router.route({:node_sheet_updated, slot_id}, {:sideways, state.router.sideways_bus}, state.router)
        
      {:error, reason} ->
        Logger.error("Actuator: Merge Failed: #{inspect(reason)}")
    end
    
    {:noreply, state}
  end

  defp execute_tool(payload, sender, state) do
    case payload.tool do
      :fs_write -> handle_fs_write(payload, sender, state)
      :fs_read -> handle_fs_read(payload, sender, state)
      :fs_copy -> handle_fs_copy(payload, sender, state)
      :exec_cmd -> handle_exec_cmd(payload, sender, state)
      :hardware_gpio -> handle_hardware_gpio(payload, sender, state)
      :generate_implementation -> handle_generate_implementation(payload, sender, state)
      :remediate_implementation -> handle_remediate_implementation(payload, sender, state)
      _ ->
        Logger.error("Unknown tool requested: #{inspect(payload.tool)}")
        {:noreply, state}
    end
  end

  defp handle_remediate_implementation(payload, sender, state) do
     Logger.info("Actuator: Starting REMEDIATION...")
     
     directive = payload.directive || payload["directive"]
     
     # DETECT LANGUAGE CONSTRAINTS
     target_path = directive.target_path || ""
       
     # 1. Load Profile (Remediator)
     # DEFENSIVE: Ensure all pillars exist to prevent EEx render errors
     raw_ctx = directive.full_context || %{}
     _ctx_shadow = 
       case raw_ctx do
         %ACN.Infrastructure.Lattice.DeepContext{} = dc -> Map.from_struct(dc)
         map when is_map(map) -> map
         _ -> %{}
       end

     # ATOMIZE KEYS: Fix String (JSON) vs Atom (Template) mismatch
     # We manually extract and reconstruct the struct-like map to ensure template compatibility
     ctx_blueprint = raw_ctx["blueprint"] || raw_ctx[:blueprint]
     raw_rules = Map.get(raw_ctx, "rules") || Map.get(raw_ctx, :rules) || %{}
     ctx_rules = %{
        master: Map.get(raw_rules, "master") || Map.get(raw_rules, :master) || [],
        ancestral: Map.get(raw_rules, "ancestral") || Map.get(raw_rules, :ancestral) || [],
        local: Map.get(raw_rules, "local") || Map.get(raw_rules, :local) || []
     }
     
     raw_worksheets = Map.get(raw_ctx, "worksheets") || Map.get(raw_ctx, :worksheets) || %{}
     ctx_worksheets = %{
        parent: Map.get(raw_worksheets, "parent") || Map.get(raw_worksheets, :parent),
        grandparent: Map.get(raw_worksheets, "grandparent") || Map.get(raw_worksheets, :grandparent),
        great_grandparent: Map.get(raw_worksheets, "great_grandparent") || Map.get(raw_worksheets, :great_grandparent)
     }
     
     ctx_task = Map.get(raw_ctx, "task") || Map.get(raw_ctx, :task) || directive.task || "Unknown"
     ctx_acms = Map.get(raw_ctx, "acms_results") || Map.get(raw_ctx, :acms_results) || []

     ctx = %{
       blueprint: ctx_blueprint || "No inherited blueprint.",
       rules: ctx_rules,
       worksheets: ctx_worksheets,
       acms_results: ctx_acms,
       task: ctx_task,
       path: target_path
     }


     vars = %{
       rejection_reason: directive.rejection_reason || "No reason provided.",
       file_content: directive.file_content || "No content available.",
       path: target_path,
       context: ctx,
       deep_context: ctx,
       blueprint_spec: directive[:blueprint_spec] || "No blueprint available."
     }
     
     case ProfileLoader.load("actuator_remediator", vars) do
       {:ok, profile} ->
          buffer = ContextBuffer.new(profile["system_prompt"])
          
          # Use AI
          adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
          config = %{
             adapter: adapter, 
             opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"],
             stop_after_tools: true
          }

          # Phase 1 Fix: Inject node_id into pipeline env for correct workspace resolution.
          pipeline_env = %{
            node_id: get_in(directive, [:node_id]) || get_in(directive, ["node_id"]) || "root",
            working_path: get_in(directive, [:target_path]) || get_in(directive, ["target_path"]) || ""
          }

          # Run Pipeline
          case Pipeline.run(buffer, ["write_to_file"], config, pipeline_env) do
             {:ok, msg, new_buffer, _} ->
                # Extract details
                details = extract_execution_details(msg)
                code = details.code
                
                # Prioritize tool path if available, NO DEFAULTS
                path = 
                  if details.path && details.path != "" do
                     details.path
                  else
                     directive.target_path
                  end
                
                # STRICT VALIDATION: No defaults, path must be a valid file
                cond do
                  is_nil(path) || path == "" ->
                     Logger.error("Actuator: No file path provided. AI must specify target path in tool call.")
                     Router.route({:action_failure, "No file path provided by AI or Legislator"}, {:local, sender}, state.router)
                  
                  File.dir?(path) ->
                     Logger.error("Actuator: Path #{path} is a directory, not a file. Legislator must provide file path.")
                     Router.route({:action_failure, "Path is a directory: #{path}"}, {:local, sender}, state.router)
                  
                  true ->
                     # Valid file path - proceed with write
                     node_id = get_in(directive, [:node_id]) || get_in(directive, ["node_id"]) || "root"
                     
                     # Fix 4C: Pass working_path to write_atomic to enforce Workspace Jailing
                     case ACN.Infrastructure.Workspace.write_atomic(node_id, path, code, pipeline_env.working_path) do
                       {:ok, _abs_path} -> 
                         hash = :crypto.hash(:sha256, code) |> Base.encode16()
                         # Issue 3 Fix: remove redundant push_physical that overwrote diff with nil.
                         # Issue 3 Fix: push cognitive trace for shadow files
                         Emitter.push_cognitive(%{
                           raw_prompt: inspect(new_buffer, pretty: true),
                           raw_response: msg.content || ""
                         })
                         Emitter.flush_and_broadcast(:execution, :writing, node_id)
                         Router.route({:implementation_written, path, hash}, {:local, sender}, state.router)
                       {:error, reason} ->
                         Logger.error("Actuator: Failed to write remediation: #{inspect(reason)}")
                         Router.route({:action_failure, "Filesystem Error: #{inspect(reason)}"}, {:local, sender}, state.router)
                     end
                end
                
             error ->
                Logger.error("Remediator AI Failed: #{inspect(error)}")
                Router.route({:action_failure, "AI Remediation Failed"}, {:local, sender}, state.router)
          end
          
       {:error, reason} ->
          Logger.error("Failed to load remediator profile: #{inspect(reason)}")
          Router.route({:action_failure, "Profile Load Failed"}, {:local, sender}, state.router)
     end
     
     {:noreply, state}
  end

  defp handle_generate_implementation(payload, sender, state) do
     Logger.info("Actuator: Generating Implementation...")
     
     directive = payload.directive || payload["directive"]
     
     # DETECT LANGUAGE CONSTRAINTS
     target_path = directive.target_path || ""
     language_instruction = 
       cond do
         String.ends_with?(target_path, ".py") -> "IMPORTANT: You MUST write valid PYTHON code."
         String.ends_with?(target_path, ".ex") -> "IMPORTANT: You MUST write valid ELIXIR code."
         String.ends_with?(target_path, ".js") -> "IMPORTANT: You MUST write valid JAVASCRIPT code."
         String.ends_with?(target_path, ".java") -> "IMPORTANT: You MUST write valid JAVA code."
         String.ends_with?(target_path, ".go") -> "IMPORTANT: You MUST write valid GO code."
         true -> ""
       end
       
     final_instruction = 
       if language_instruction != "" do
         "#{language_instruction}\n\n#{directive.task || "No instruction"}"
       else
         directive.task || "No instruction"
       end

     # 1. Load Profile (Code Drafter)
     # We use the existing 'specialist_drafter' profile which is tuned for this.
     # DEFENSIVE: Ensure all pillars exist to prevent EEx render errors
     raw_ctx = directive.full_context || %{}
      ctx_shadow = 
        case raw_ctx do
          %ACN.Infrastructure.Lattice.DeepContext{} = dc -> Map.from_struct(dc)
          map when is_map(map) -> map
          _ -> %{}
        end

      ctx = Map.merge(%{
        blueprint: "No inherited blueprint.",
        rules: %ACN.Infrastructure.Lattice.DeepContext.Rules{},
        worksheets: %{parent: nil, grandparent: nil, great_grandparent: nil},
        acms_results: [],
        task: directive.task || "Unknown",
        path: target_path
      }, ctx_shadow)

     vars = %{
       instruction: final_instruction,
       rules: directive.rules || [],
       path: target_path,
       context: ctx,
       deep_context: ctx,
       blueprint_spec: directive[:blueprint_spec] || "No blueprint available."
     }
     
     # Note: We might need to map 'directive.full_context' fields to what profile expects.
     # specialist_drafter likely needs 'codebase_map', 'ancestral_memory', etc.
     
     # For now, we pass the struct/map.
     
      case ProfileLoader.load("specialist_drafter", vars) do
       {:ok, profile} ->
          buffer = ContextBuffer.new(profile["system_prompt"])
          
          # Use AI
          adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OllamaAdapter
          config = %{
             adapter: adapter, 
             opts: [model: profile["model"], temperature: profile["temperature"], tool_choice: "ANY"],
             stop_after_tools: true # Depending on if it uses tools or content
          }

          # Phase 1 Fix: Inject node_id and working_path into the pipeline env so
          # that write_to_file tool resolves files within the correct node workspace.
          pipeline_env = %{
            node_id: get_in(directive, [:node_id]) || get_in(directive, ["node_id"]) || "root",
            working_path: get_in(directive, [:target_path]) || get_in(directive, ["target_path"]) || ""
          }
          
          # Run Pipeline
          case Pipeline.run(buffer, ["write_to_file"], config, pipeline_env) do
             {:ok, msg, new_buffer, _} ->
                # Extract details
                details = extract_execution_details(msg)
                code = details.code
                
                # Prioritize tool path if available, NO DEFAULTS
                path = 
                  if details.path && details.path != "" do
                     details.path
                  else
                     directive.target_path
                  end
                
                # Write Direct
                Logger.info("Actuator: Writing code to #{path}")
                
                # STRICT VALIDATION: No defaults, path must be a valid file
                cond do
                  is_nil(path) || path == "" ->
                     Logger.error("Actuator: No file path provided. AI must specify target path in tool call.")
                     Router.route({:action_failure, "No file path provided by AI or Legislator"}, {:local, sender}, state.router)
                  
                  File.dir?(path) ->
                     Logger.error("Actuator: Path #{path} is a directory, not a file. Legislator must provide file path.")
                     Router.route({:action_failure, "Path is a directory: #{path}"}, {:local, sender}, state.router)
                  
                  true ->
                     # Valid file path - proceed with write
                     node_id = get_in(directive, [:node_id]) || get_in(directive, ["node_id"]) || "root"
                     
                     # Fix 4C: Pass working_path to write_atomic to enforce Workspace Jailing
                     case ACN.Infrastructure.Workspace.write_atomic(node_id, path, code, pipeline_env.working_path) do
                       {:ok, _abs_path} ->
                         hash = :crypto.hash(:sha256, code) |> Base.encode16()
                         # Issue 3 Fix: remove redundant push_physical that overwrote diff with nil.
                         # Issue 3 Fix: push cognitive trace for shadow files
                         Emitter.push_cognitive(%{
                           raw_prompt: inspect(new_buffer, pretty: true),
                           raw_response: msg.content || ""
                         })
                         Emitter.flush_and_broadcast(:execution, :writing, node_id)
                         Router.route({:implementation_written, path, hash}, {:local, sender}, state.router)
                       {:error, reason} ->
                         Logger.error("Actuator: Failed to write implementation: #{inspect(reason)}")
                         Router.route({:action_failure, "Filesystem Error: #{inspect(reason)}"}, {:local, sender}, state.router)
                     end
                end
                
             error ->
                Logger.error("Drafter AI Failed: #{inspect(error)}")
                Router.route({:action_failure, "AI Generation Failed"}, {:local, sender}, state.router)
          end
          
       {:error, reason} ->
          Logger.error("Failed to load drafter profile: #{inspect(reason)}")
          Router.route({:action_failure, "Profile Load Failed"}, {:local, sender}, state.router)
     end
     
     {:noreply, state}
  end
  
  defp extract_execution_details(msg) do
     # Try to find tool call
     case Map.get(msg, :tool_calls) do
        [%{"function" => %{"name" => "write_to_file", "arguments" => args_json}} | _] ->
           case Jason.decode(args_json) do
               {:ok, args} -> 
                   %{
                     code: args["content"], 
                     path: args["path"]
                   }
               _ -> 
                   %{code: msg.content, path: nil}
           end
        _ -> 
           # Fallback: Extract Markdown code block
           code = 
             Regex.run(~r/```(?:elixir|python|ex|js|java|go)?\s*(.*?)```/s, msg.content)
             |> case do
                 [_, c] -> String.trim(c)
                 _ -> msg.content # Raw
             end
           %{code: code, path: nil}
     end
  end

  defp handle_hardware_gpio(payload, sender, state) do
     pin = payload.args.pin || payload.args["pin"]
     # Check Safe Pin List (Configured or Hardcoded)
     # Pins 1-10 are unsafe (e.g. system fans, cpu)
     unsafe_pins = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
 
     if pin in unsafe_pins do
        Logger.error("SECURITY ALERT: Attempt to access UNSAFE PIN #{pin}")
        Router.route({:action_failure, "Security Violation: Unsafe Pin"}, {:local, sender}, state.router)
     else
        adapter = Application.get_env(:acn, :hardware_adapter)
        state_val = payload.args.state || payload.args["state"]
 
        # We only support write for now based on tool definition
        res =
          case state_val do
             "high" -> adapter.gpio_write(pin, :high)
             "low" -> adapter.gpio_write(pin, :low)
             _ -> {:error, :invalid_state}
          end
 
        case res do
          :ok -> Router.route({:action_success, "GPIO #{pin} set to #{state_val}", "hardware"}, {:local, sender}, state.router)
          {:error, reason} -> Router.route({:action_failure, reason}, {:local, sender}, state.router)
        end
     end
     {:noreply, state}
  end

  # --- Tool Implementations ---

  defp handle_exec_cmd(payload, sender, state) do
    command = payload.args.command || payload.args["command"]
    args = payload.args.args || payload.args["args"] || []
    node_id = get_in(payload, [:directive, :target_path]) || get_in(payload, ["directive", "target_path"]) || payload.args.node_id || payload.args["node_id"] || state.node_id

    # Resolve CWD for Sandbox
    cwd = ACN.Infrastructure.Workspace.resolve(node_id)
    # Ensure directory exists
    File.mkdir_p!(cwd)

    case Sandbox.run(command, args, [cd: cwd]) do
      {:ok, output, code} ->
        :telemetry.execute([:acn, :actuator, :exec], %{exit_code: code}, %{command: command})

        if code == 0 do
           Router.route({:action_result, output, 0}, {:local, sender}, state.router)
        else
           Router.route({:action_failure, "Exit Code: #{code}\nOutput: #{output}"}, {:local, sender}, state.router)
        end

      {:error, reason} ->
        Router.route({:action_failure, reason}, {:local, sender}, state.router)
      
      # Handle direct Sandbox result map (legacy compatibility or if Sandbox returns map)
      %{stdout: output, stderr: stderr, exit_code: code} ->
         if code == 0 do
           Router.route({:action_result, output, 0}, {:local, sender}, state.router)
         else
           Router.route({:action_failure, "Exit Code: #{code}\nStderr: #{stderr}\nStdout: #{output}"}, {:local, sender}, state.router)
         end
    end
    {:noreply, state}
  end

  defp handle_fs_write(payload, sender, state) do
    # Pass the actual working path (target_path) instead of just node_id
    # so workspace.ex resolution uses the correct nested folder.
    args = payload.args
    node_id = get_in(payload, [:directive, :target_path]) || get_in(payload, ["directive", "target_path"]) || args["node_id"] || Map.get(args, :node_id, state.node_id)
    path = args["path"] || Map.get(args, :path)
    content = args["content"] || Map.get(args, :content)
    # Use safe access to avoid KeyError if key is missing
    mode = args["mode"] || Map.get(args, :mode, "overwrite")
 
    result = 
      case mode do
        "append" -> 
          ACN.Infrastructure.Workspace.append(node_id, path, content)
        
        "patch" ->
          # Content here is the diff string
          ACN.Infrastructure.Workspace.apply_patch(node_id, path, content)
          
        _ -> 
          # Default: Overwrite
          ACN.Infrastructure.Workspace.write_atomic(node_id, path, content)
      end
 
    case result do
      {:ok, _abs_path} ->
        :telemetry.execute([:acn, :actuator, :file_write], %{size: byte_size(content)}, %{path: path, node_id: node_id, mode: mode})
 
        # Calculate new hash for verification
        # We need to read the file back to get the full hash if we appended/patched
        full_content_hash = 
          case ACN.Infrastructure.Workspace.read_artifact(node_id, path) do
            {:ok, full_data} -> :crypto.hash(:sha256, full_data) |> Base.encode16()
            _ -> "hash_unavailable"
          end

        # HSG: emit physical vector for fs_write tool
        Emitter.push_physical(%{
          file_path:  path,
          operation:  String.to_atom(mode),
          unified_diff: (if mode == "patch", do: content, else: nil),
          checksum_after: full_content_hash
        })
        Emitter.flush_and_broadcast(:execution, :writing, node_id)
 
        Router.route({:action_success, full_content_hash, path}, {:local, sender}, state.router)
 
      {:error, reason} ->
         Router.route({:action_failure, "Write(#{mode}) Failed: #{inspect(reason)}"}, {:local, sender}, state.router)
    end
    {:noreply, state}
  end

  defp handle_fs_copy(payload, sender, state) do
    args = payload.args
    source = args["source"] || Map.get(args, :source)
    dest = args["dest"] || Map.get(args, :dest)
    node_id = args["node_id"] || Map.get(args, :node_id, "root")

    case ACN.Infrastructure.Workspace.copy_artifact(node_id, source, dest) do
      {:ok, path} ->
        Router.route({:action_success, "copy", path}, {:local, sender}, state.router)
      {:error, reason} ->
        Router.route({:action_failure, reason}, {:local, sender}, state.router)
    end
  end

  defp handle_fs_read(payload, sender, state) do
    node_id = payload.args[:node_id] || payload.args["node_id"] || "root"
    path = payload.args.path || payload.args["path"]
 
    # Use Safe Path to read
    case ACN.Infrastructure.Workspace.safe_path(node_id, path) do
      {:ok, abs_path} ->
        case File.read(abs_path) do
          {:ok, content} ->
            Router.route({:action_result, content}, {:local, sender}, state.router)
          {:error, reason} ->
            Router.route({:action_failure, reason}, {:local, sender}, state.router)
        end
 
      {:error, reason} ->
         Router.route({:action_failure, "Security Violation: #{inspect(reason)}"}, {:local, sender}, state.router)
    end
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp validate_access!(payload, state) do
    if is_nil(state.public_key) do
      {:error, :security_system_offline}
    else
      token = payload.token || payload["token"]

      # Determine required scope based on tool
      required_scope =
        case payload.tool do
          :fs_write -> :fs_write
          :exec_cmd -> :exec_cmd
          :fs_read -> :fs_read
          :fs_copy -> :actuator
          :hardware_gpio -> :actuator
          :generate_implementation -> :actuator
          :remediate_implementation -> :actuator
          _ -> :unknown
        end

      # Determine requested resource for locking
      args = Map.get(payload, :args) || Map.get(payload, "args") || %{}
      
      requested_args = 
         case payload.tool do
            :generate_implementation -> 
               # For generation, the resource is the target path inside the directive
               get_in(payload, [:directive, :target_path]) || "unknown"
            :remediate_implementation ->
               # Same for remediation
               get_in(payload, [:directive, :target_path]) || "unknown"
            _ -> 
               # For others, it's usually in args
               args
         end

      # Verify
      # FIX: Always use the synced Controller Public Key (state.public_key) for Actuator tasks.
      key_to_use = state.public_key
      
      if key_to_use do
          result = case TokenAuthority.verify(token, key_to_use, required_scope, requested_args) do
             {:error, :signature_error} ->
                 Logger.warning("Actuator: Signature Verification Failed. Attempting Key Refresh and Retry...")
                 # Attempt synchronous refresh
                 new_key = fetch_key_synchronously(state.node_id)
                 if new_key do
                     TokenAuthority.verify(token, new_key, required_scope, requested_args)
                 else
                     {:error, :signature_error}
                 end
             r -> r
          end

          # HSG: Emit security vector so the Immune System table captures every auth decision
          jwt_jti = try do
            case Jason.decode(Base.url_decode64!(String.split(token || "", ".") |> Enum.at(1, ""), padding: false)) do
              {:ok, %{"jti" => jti}} -> jti
              _ -> nil
            end
          rescue _ -> nil end

          Emitter.push_security(%{
            jwt_jti:         jwt_jti,
            required_scopes: [required_scope],
            granted_scopes:  (if match?({:ok, _}, result), do: [required_scope], else: []),
            target_path:     to_string(requested_args),
            outcome:         (if match?({:ok, _}, result), do: :granted, else: :denied)
          })

          result
      else
          # Try to fetch key now
          new_key = fetch_key_synchronously(state.node_id)
          if new_key do
             TokenAuthority.verify(token, new_key, required_scope, requested_args)
          else
             {:error, :no_public_key}
          end
      end
    end
  end
end
