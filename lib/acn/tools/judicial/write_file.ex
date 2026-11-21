defmodule ACN.Tools.Judicial.WriteFile do
  @behaviour ACN.Tools.ToolBehaviour

  alias ACN.Tools.Judicial.WorkspaceFile

  @impl true
  def definition do
    %{
      "name" => "judicial_write_file",
      "description" => "Writes a corrected file within the task workspace. Existing files are backed up before replacement. Use for focused corrections; use submit_verdict with REJECTED when a substantial rewrite should return to the drafter.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute or workspace-relative file path."},
          "content" => %{"type" => "string", "description" => "Complete corrected file content."}
        },
        "required" => ["path", "content"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    with {:ok, path} <- WorkspaceFile.resolve(args, env),
         content when is_binary(content) <- args["content"] || args[:content] do
      WorkspaceFile.write(path, content, env)
    else
      nil -> {:error, "Missing required file content."}
      {:error, reason} -> {:error, "Could not resolve task workspace path: #{inspect(reason)}"}
      _ -> {:error, "File content must be a string."}
    end
  end
end
