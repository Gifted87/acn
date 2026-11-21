defmodule ACN.Tools.Judicial.ReadFile do
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      "name" => "judicial_read_file",
      "description" => "Reads a file from the task workspace for evidence-based review.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path."}
        },
        "required" => ["path"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    with {:ok, path} <- workspace_path(args, env),
         {:ok, content} <- File.read(path) do
      {:ok, "FILE: #{path}\n#{content}"}
    else
      {:error, reason} -> {:error, "Could not read workspace file: #{inspect(reason)}"}
    end
  end

  defp workspace_path(args, env) do
    node_id = env[:node_id] || "root"
    path = args["path"] || Map.get(args, :path)

    if is_binary(path) and path != "" do
      {:ok, Path.expand(path, env[:working_path] || ACN.Infrastructure.Workspace.resolve(node_id))}
    else
      {:error, :missing_path}
    end
  end
end
