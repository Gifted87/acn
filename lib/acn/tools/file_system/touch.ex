defmodule ACN.Tools.FileSystem.Touch do
  @moduledoc """
  Exposes the 'touch' capability to agents.
  """
  @behaviour ACN.Tools.ToolBehaviour

  require Logger
  alias ACN.Infrastructure.Workspace

  @impl true
  def definition do
    %{
      name: "touch",
      description: "Creates a file at the specified path (touch).",
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "The absolute path to the file to create."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    path = args["path"] || args[:path]
    node_id = Map.get(env, :node_id, "root")
    working_path = Map.get(env, :working_path)

    Logger.info("Tool [touch] executed for #{path}")

    # Implicitly ensure directory exists to prevent 'enoent' for the user
    # This is a safe helper behavior for a "smart" touch.
    Path.dirname(path) |> File.mkdir_p!()

    case Workspace.touch(node_id, path, working_path) do
      {:ok, abs_path} -> 
        {:ok, "Successfully touched #{abs_path}"}
      {:error, reason} -> 
        {:error, "Failed to touch file: #{inspect(reason)}"}
    end
  end
end
