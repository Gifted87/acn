defmodule ACN.Tools.FileSystem.Read do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      name: "fs_read",
      description: "Reads content from a specific file path within the workspace.",
      parameters: %{
        type: "object",
        properties: %{
          node_id: %{type: "string", description: "Node ID owning the workspace"},
          path: %{type: "string", description: "Relative path (e.g., lib/my_mod.ex)"}
        },
        required: ["path"]
      }
    }
  end

  def execute(_args, _env), do: {:error, :use_actuator_directly}
end
