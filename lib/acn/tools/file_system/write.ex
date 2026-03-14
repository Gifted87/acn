defmodule ACN.Tools.FileSystem.Write do
  @moduledoc """
  Exposes file writing capabilities to agents.
  """
  @behaviour ACN.Tools.ToolBehaviour

  require Logger
  alias ACN.Infrastructure.Workspace

  @impl true
  def definition do
    %{
      name: "write_to_file",
      description: "Writes content to a file at the specified path. Supports creating new files or overwriting existing ones.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "The absolute path to the file to write."
          },
          content: %{
            type: "string",
            description: "The text content to write to the file."
          },
          mode: %{
            type: "string",
            enum: ["overwrite", "append"],
            description: "Mode operation. Default is overwrite."
          }
        },
        required: ["path", "content"]
      }
    }
  end

  @impl true
  def execute(args, context) do
    path = args["path"] || args[:path]
    content = args["content"] || args[:content]
    mode = args["mode"] || args[:mode] || "overwrite"

    # Resolve node_id from the calling node's context (injected by Actuator).
    # Falling back to "root" is the last resort — if this happens in production,
    # it means the Actuator forgot to set the env before running the Pipeline.
    node_id = context[:node_id] || context["node_id"] || "root"

    if node_id == "root" do
      Logger.warning("Tool [write_to_file] fallback to 'root' node_id. Actuator may not have injected context.")
    end

    Logger.info("Tool [write_to_file] executed for #{path} (node: #{node_id})")

    case mode do
      "append" -> Workspace.append(node_id, path, content)
      _ -> Workspace.write_atomic(node_id, path, content)
    end
    |> case do
      {:ok, abs_path} -> 
        {:ok, "Successfully wrote to #{abs_path}"}
      {:error, reason} -> 
        {:error, "Failed to write file: #{inspect(reason)}"}
    end
  end
end
