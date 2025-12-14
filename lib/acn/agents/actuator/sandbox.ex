defmodule ACN.Agents.Actuator.Sandbox do
  @moduledoc """
  Manages the lifecycle of the Firecracker MicroVM.
  Acts as the "Function-as-a-Service" provider.
  """
  require Logger
  alias ACN.Actuator.RustlerBridge

  @doc """
  Executes a command inside the isolated Sandbox.
  1. Boot VM
  2. Run Command
  3. Teardown
  """
  def run(command, args) do
    if Application.get_env(:acn, :simulation_mode, false) do
      run_simulation(command, args)
    else
      run_firecracker(command, args)
    end
  end

  defp run_firecracker(command, args) do
    # 1. Prepare Infrastructure
    uuid = UUID.uuid4()
    socket_path = "/tmp/acn_#{uuid}.socket"
    
    # 2. Spawn Firecracker
    # We must ensure previous socket is gone
    File.rm(socket_path)
    
    port = spawn_firecracker(socket_path)
    Logger.debug("Sandbox: VM #{uuid} spawned on #{socket_path}")

    try do
      # 3. Bridge Call (Blocking)
      # The NIF handles the connect/boot/exec sequence
      case RustlerBridge.run_cmd(socket_path, command, args) do
        {res, stdout, stderr, code} when res in [:ok] ->
           %{stdout: stdout, stderr: stderr, exit_code: code}
           
        {:error, reason} ->
           Logger.error("Sandbox NIF Error: #{reason}")
           %{stdout: "", stderr: reason, exit_code: -1}
      end
    rescue
      e -> 
        Logger.error("Sandbox Exception: #{inspect(e)}")
        %{stdout: "", stderr: "Internal Sandbox Error", exit_code: -1}
    after
      # 4. Cleanup
      terminate_port(port)
      File.rm(socket_path)
      File.rm("#{socket_path}.vsock") 
    end
  end

  defp run_simulation(command, args) do
    Logger.warning("Sandbox: RUNNING LOCAL (Simulation Mode). Command: #{command}")
    
    # Concrete Implementation: Run on Host System
    # Security Warning: This runs with the same permissions as the BEAM node.
    case System.cmd(command, args, stderr_to_stdout: false) do
      {output, 0} -> 
        %{stdout: output, stderr: "", exit_code: 0}
      {output, code} -> 
        %{stdout: "", stderr: output, exit_code: code}
    end
  rescue
    e -> 
       %{stdout: "", stderr: "Local Execution Failed: #{inspect(e)}", exit_code: -1}
  end

  defp spawn_firecracker(socket_path) do
    executable = System.find_executable("firecracker") || "firecracker"
    
    # Start Firecracker listening on UDS
    Port.open({:spawn_executable, executable}, [
      :binary, 
      :exit_status, 
      args: ["--api-sock", socket_path]
    ])
  end

  defp terminate_port(port) do
    if port do
      Port.close(port) 
      # Port.close sends SIGTERM/KILL to linked process
    end
  end
end
