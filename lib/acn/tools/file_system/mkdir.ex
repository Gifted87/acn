defmodule ACN.Tools.FileSystem.Mkdir do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "mkdir",
      "description" => "Creates a directory at the given path, including parent directories if they don't exist.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The absolute path of the directory to create."
          }
        },
        "required" => ["path"]
      }
    }
  end

  def execute(args, env) do
    path = args["path"]
    node_id = Map.get(env, :node_id, "root")
    working_path = Map.get(env, :working_path)
    
    case ACN.Infrastructure.Workspace.safe_path(node_id, path, working_path) do
      {:ok, safe_path} -> 
        case File.mkdir_p(safe_path) do
          :ok -> "Directory created: #{safe_path}"
          {:error, reason} -> "Failed to create directory: #{inspect(reason)}"
        end
      {:error, reason} ->
         "Failed to create directory (Spatial Violation): #{inspect(reason)}"
    end
  end
end
