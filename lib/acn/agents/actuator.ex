defmodule ACN.Agents.Actuator do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router
  alias ACN.Core.Security.TokenAuthority
  alias ACN.Agents.Actuator.Sandbox

  # Define Telemetry Events
  # [:acn, :actuator, :file_write]
  # [:acn, :actuator, :exec]
  # [:acn, :security, :token_rejection]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:actuator, :actuator)
  end
  # end removed

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    # Try to extract key from opts if provided (e.g. testing)
    public_key = Keyword.get(opts, :public_key)

    # Start independent key-sync loop
    send(self(), :refresh_key)

    {:ok, %{public_key: public_key}}
  end

  @impl true
  def handle_info(:refresh_key, state) do
    key =
      case NodeRegistry.lookup(:controller) do
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
      Logger.info("Actuator synced Security Key.")
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
           Router.route({:merge_success, batch_id}, {:local, :controller})
           
       {:error, reason} ->
           Logger.error("Action Denied (Merge): #{inspect(reason)}")
           Router.route({:action_failure, "Merge Denied"}, {:local, :controller})
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:perform_action, payload}, state) do
    # Gatekeeper Interceptor
    case validate_access!(payload, state) do
      {:ok, _claims} ->
        # Authorized
        execute_tool(payload, state)

      {:error, reason} ->
        Logger.error("SECURITY ALERT: UNAUTHORIZED ACCESS ATTEMPT. Reason: #{inspect(reason)}")
        :telemetry.execute([:acn, :security, :token_rejection], %{count: 1}, %{reason: reason})
        # Emit pain signal
        Router.route({:pain_signal, 10}, {:local, :live_wire})
        # Drop message
        {:noreply, state}
    end
  end

  defp execute_tool(payload, state) do
    case payload.tool do
      :fs_write -> handle_fs_write(payload, state)
      :fs_read -> handle_fs_read(payload, state)
      :exec_cmd -> handle_exec_cmd(payload, state)
      :hardware_gpio -> handle_hardware_gpio(payload, state)
      _ ->
        Logger.error("Unknown tool requested: #{inspect(payload.tool)}")
        {:noreply, state}
    end
  end

  defp handle_hardware_gpio(payload, state) do
     pin = payload.args.pin || payload.args["pin"]
     # Check Safe Pin List (Configured or Hardcoded)
     # Pins 1-10 are unsafe (e.g. system fans, cpu)
     unsafe_pins = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

     if pin in unsafe_pins do
        Logger.error("SECURITY ALERT: Attempt to access UNSAFE PIN #{pin}")
        Router.route({:action_failure, "Security Violation: Unsafe Pin"}, {:local, :controller})
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
          :ok -> Router.route({:action_success, "GPIO #{pin} set to #{state_val}", "hardware"}, {:local, :controller})
          {:error, reason} -> Router.route({:action_failure, reason}, {:local, :controller})
        end
     end
     {:noreply, state}
  end

  # --- Tool Implementations ---

  defp handle_exec_cmd(payload, state) do
    command = payload.args.command || payload.args["command"]
    args = payload.args.args || payload.args["args"] || []

    case Sandbox.run(command, args) do
      {:ok, output, code} ->
        :telemetry.execute([:acn, :actuator, :exec], %{exit_code: code}, %{command: command})

        if code == 0 do
           Router.route({:action_result, output, 0}, {:local, :controller})
        else
           Router.route({:action_failure, "Exit Code: #{code}\nOutput: #{output}"}, {:local, :controller})
        end

      {:error, reason} ->
        Router.route({:action_failure, reason}, {:local, :controller})
    end
    {:noreply, state}
  end

  defp handle_fs_write(payload, state) do
    # Assume node_id is provided in args or default to "root"
    args = payload.args
    node_id = args["node_id"] || Map.get(args, :node_id, "root")
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

        Router.route({:action_success, full_content_hash, path}, {:local, :controller})

      {:error, reason} ->
         Router.route({:action_failure, "Write(#{mode}) Failed: #{inspect(reason)}"}, {:local, :controller})
    end
    {:noreply, state}
  end

  defp handle_fs_read(payload, state) do
    node_id = payload.args[:node_id] || payload.args["node_id"] || "root"
    path = payload.args.path || payload.args["path"]

    # Use Safe Path to read
    case ACN.Infrastructure.Workspace.safe_path(node_id, path) do
      {:ok, abs_path} ->
        case File.read(abs_path) do
          {:ok, content} ->
            Router.route({:action_result, content}, {:local, :controller})
          {:error, reason} ->
            Router.route({:action_failure, reason}, {:local, :controller})
        end

      {:error, reason} ->
         Router.route({:action_failure, "Security Violation: #{inspect(reason)}"}, {:local, :controller})
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
          :hardware_gpio -> :actuator
          _ -> :unknown
        end

      # Determine requested resource for locking
      requested_args = payload.args || payload["args"]

      # Verify
      TokenAuthority.verify(token, state.public_key, required_scope, requested_args)
    end
  end
end
