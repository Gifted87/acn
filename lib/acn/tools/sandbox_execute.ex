defmodule ACN.Tools.Sandbox.Execute do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      name: "exec_cmd",
      description: "Executes a shell command inside the secure sandbox environment.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The binary to run (e.g., mix)"},
          args: %{type: "array", items: %{type: "string"}, description: "List of arguments (e.g., ['test'])"},
          node_id: %{type: "string", description: "The workspace node ID to run in (default: 'root')"},
          timeout: %{type: "integer", description: "Max execution time in ms (default 5000)"}
        },
        required: ["command", "args"]
      }
    }
  end

  def execute(_args, _env), do: {:error, :use_actuator_directly}
end
