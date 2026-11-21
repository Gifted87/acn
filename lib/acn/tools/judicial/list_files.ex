defmodule ACN.Tools.Judicial.ListFiles do
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      "name" => "judicial_list_files",
      "description" => "Recursively lists files and directories.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Directory path, default is the task workspace."}
        },
        "required" => []
      }
    }
  end

  @impl true
  def execute(args, env) do
    node_id = env[:node_id] || "root"
    working_path = env[:working_path] || ACN.Infrastructure.Workspace.resolve(node_id)
    relative = args["path"] || Map.get(args, :path) || "."

    root = Path.expand(relative, working_path)
    {:ok, "Directory listing for #{root}:\n" <> Enum.join(walk(root, root, []), "\n")}
  end

  defp walk(root, directory, entries) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(names, entries, fn name, acc ->
          full = Path.join(directory, name)
          relative = Path.relative_to(full, root)

          case File.stat(full) do
            {:ok, %{type: :directory}} ->
              nested = walk(root, full, [relative <> "/" | acc])
              {:cont, nested}

            {:ok, %{type: :regular}} ->
              next = [relative | acc]
              {:cont, next}

            _ -> {:cont, acc}
          end
        end)
      {:error, _} -> entries
    end
  end
end
