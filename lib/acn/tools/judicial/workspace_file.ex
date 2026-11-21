defmodule ACN.Tools.Judicial.WorkspaceFile do
  @moduledoc false

  alias ACN.Infrastructure.Workspace

  def resolve(args, env) do
    node_id = env[:node_id] || env["node_id"] || "root"
    working_path = env[:working_path] || env["working_path"] || Workspace.resolve(node_id)
    path = args["path"] || args[:path]

    if is_binary(path) and path != "" do
      Workspace.safe_path(node_id, path, working_path)
    else
      {:error, :missing_path}
    end
  end

  def write(path, content, env) when is_binary(content) do
    node_id = env[:node_id] || env["node_id"] || "root"
    working_path = env[:working_path] || env["working_path"] || Workspace.resolve(node_id)

    case Workspace.write_atomic(node_id, path, content, working_path) do
      {:ok, written_path} ->
        hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :upper)
        {:ok, "Updated #{written_path} (SHA-256: #{hash})."}

      {:error, reason} ->
        {:error, "Could not write #{path}: #{inspect(reason)}"}
    end
  end

  def write(_path, _content, _env), do: {:error, "File content must be a string."}
end
