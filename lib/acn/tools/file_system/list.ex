defmodule ACN.Tools.FileSystem.List do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      name: "fs_list",
      description: "Lists files in the workspace directory (recursive or simple).",
      parameters: %{
        type: "object",
        properties: %{
          node_id: %{type: "string", description: "Node ID owning the workspace"},
          path: %{type: "string", description: "Relative path to list (default root)"}
        },
        required: []
      }
    }
  end

  def execute(_args), do: {:error, :use_actuator_directly}
end
