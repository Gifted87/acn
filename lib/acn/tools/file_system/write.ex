defmodule ACN.Tools.FileSystem.Write do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      name: "fs_write",
      description: "Writes text content to a specific file path within the workspace.",
      parameters: %{
        type: "object",
        properties: %{
          node_id: %{type: "string", description: "Node ID owning the workspace"},
          path: %{type: "string", description: "Relative path (e.g., lib/my_mod.ex)"},
          content: %{type: "string", description: "The file content, text to append, or Unified Diff."},
          mode: %{
            type: "string", 
            enum: ["overwrite", "append", "patch"], 
            description: "Default is overwrite. Use 'patch' for small code edits. Use 'append' for logs."
          }
        },
        required: ["path", "content"]
      }
    }
  end

  def execute(_args), do: {:error, :use_actuator_directly}
end
