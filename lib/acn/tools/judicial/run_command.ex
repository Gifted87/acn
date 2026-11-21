defmodule ACN.Tools.Judicial.RunCommand do
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      "name" => "judicial_run_command",
      "description" =>
        "Runs any terminal command or shell script in the task workspace. Supports persistent local servers with start_server, poll, and stop.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "mode" => %{"type" => "string"},
          "command" => %{"type" => "string", "description" => "Any shell command or script."},
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory; defaults to the task workspace."
          },
          "session_id" => %{"type" => "string"}
        },
        "required" => ["command"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    mode = args["mode"] || Map.get(args, :mode) || "run"
    command = args["command"] || Map.get(args, :command) || ""
    node_id = env[:node_id] || "root"
    working_path = env[:working_path] || ACN.Infrastructure.Workspace.resolve(node_id)
    cwd = args["cwd"] || Map.get(args, :cwd) || working_path

    case mode do
      "poll" -> poll_server(args)
      "stop" -> stop_server(args)
      "start_server" -> start_server(command, cwd)
      "run" -> run_command(command, cwd)
      _ -> {:error, "Unknown command mode: #{inspect(mode)}"}
    end
  end

  def cleanup do
    Process.get()
    |> Enum.each(fn
      {{__MODULE__, session_id}, port} when is_binary(session_id) and is_port(port) ->
        safe_close_port(port)
        Process.delete({__MODULE__, session_id})

      _ ->
        :ok
    end)

    :ok
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
      :exit, _reason -> :ok
    end
  end

  defp run_command(command, cwd) do
    port = shell_port(command, cwd)
    {output, status} = collect(port, <<>>, nil)
    {:ok, "Command: #{command}\nExit code: #{status}\n#{output}"}
  rescue
    error -> {:error, "Command could not be run: #{Exception.message(error)}"}
  end

  defp start_server(command, cwd) do
    port = shell_port(command, cwd)
    session_id = "judicial-#{UUID.uuid4()}"
    Process.put({__MODULE__, session_id}, port)
    {:ok, "Started command in #{cwd}. Session ID: #{session_id}."}
  rescue
    error -> {:error, "Could not start command: #{Exception.message(error)}"}
  end

  defp poll_server(args) do
    session_id = args["session_id"] || Map.get(args, :session_id)

    case Process.get({__MODULE__, session_id}) do
      port when is_port(port) ->
        {output, status} = drain(port, <<>>, nil)
        if is_integer(status), do: Process.delete({__MODULE__, session_id})

        {:ok,
         "#{if is_integer(status), do: "Process exited with status #{status}.", else: "Process is running."}\n#{output}"}

      _ ->
        {:error, "No process session found for #{inspect(session_id)}."}
    end
  end

  defp stop_server(args) do
    session_id = args["session_id"] || Map.get(args, :session_id)

    case Process.delete({__MODULE__, session_id}) do
      port when is_port(port) ->
        safe_close_port(port)
        {:ok, "Stopped process session #{session_id}."}

      _ ->
        {:error, "No process session found for #{inspect(session_id)}."}
    end
  end

  defp shell_port(command, cwd) do
    shell = System.get_env("SHELL") || "/bin/sh"

    Port.open({:spawn_executable, shell}, [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: ["-c", command],
      cd: cwd
    ])
  end

  defp collect(port, output, status) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data, status)
      {^port, {:exit_status, value}} -> drain_after_exit(port, output, value)
      {^port, :closed} -> {output, status || 0}
    end
  end

  defp drain_after_exit(port, output, status) do
    receive do
      {^port, {:data, data}} -> drain_after_exit(port, output <> data, status)
      {^port, {:exit_status, value}} -> drain_after_exit(port, output, value)
      {^port, :closed} -> {output, status}
    after
      0 -> {output, status}
    end
  end

  defp drain(port, output, status) do
    receive do
      {^port, {:data, data}} -> drain(port, output <> data, status)
      {^port, {:exit_status, value}} -> drain(port, output, value)
      {^port, :closed} -> {output, status}
    after
      0 -> {output, status}
    end
  end
end
