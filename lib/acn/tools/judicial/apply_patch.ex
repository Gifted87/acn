defmodule ACN.Tools.Judicial.ApplyPatch do
  @behaviour ACN.Tools.ToolBehaviour

  alias ACN.Tools.Judicial.WorkspaceFile

  @impl true
  def definition do
    %{
      "name" => "judicial_apply_patch",
      "description" => "Applies a unified diff to an existing file in the task workspace. The write is backed up and confined to the workspace. Re-read and validate the file after patching.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute or workspace-relative target file."},
          "patch" => %{"type" => "string", "description" => "Unified diff containing one or more @@ hunks."}
        },
        "required" => ["path", "patch"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    patch = args["patch"] || args[:patch]

    with true <- is_binary(patch) and String.contains?(patch, "@@"),
         {:ok, path} <- WorkspaceFile.resolve(args, env),
         {:ok, current} <- File.read(path),
         {:ok, updated} <- ACN.Core.Utils.Patcher.apply_patch(current, patch),
         true <- updated != current do
      WorkspaceFile.write(path, updated, env)
    else
      false -> {:error, "Patch is missing unified-diff hunks or made no change."}
      {:error, :enoent} -> {:error, "Patch target does not exist; use judicial_write_file to create a file."}
      {:error, reason} -> {:error, "Patch failed: #{inspect(reason)}"}
      _ -> {:error, "Patch must be a unified diff string."}
    end
  end
end
