defmodule ACN.Infrastructure.Workspace do
  @moduledoc """
  Manages filesystem isolation for ACN Nodes.
  Enforces that nodes can only write within their assigned jail.
  Handles atomic writes and backups.
  """
  require Logger

  # Default root if not configured
  @default_root "tmp/acn_workspaces"

  def root_path do
     Application.get_env(:acn, :workspace_root, @default_root)
     |> Path.expand()
  end

  @doc """
  Resolves the absolute path for a node's workspace.
  """
  def resolve(node_id) do
    Path.join(root_path(), to_string(node_id))
  end

  @doc """
  Initializes the workspace for a node.
  Creates directories: /src, /test, /logs, /artifacts, /.acn/history
  """
  def init_workspace(node_id) do
    root = resolve(node_id)

    dirs = [
      Path.join(root, "src"),
      Path.join(root, "test"),
      Path.join(root, "logs"),
      Path.join(root, "artifacts"),
      Path.join(root, ".acn/history")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)

    {:ok, root}
  end

  @doc """
  Sanitizes a user-provided path to ensure it stays within the node's workspace.
  Returns {:ok, absolute_path} or {:error, :path_traversal_detected}.
  """
  def safe_path(node_id, relative_path) do
    root = resolve(node_id)
    expanded = Path.expand(relative_path, root)

    if String.starts_with?(expanded, root) do
      {:ok, expanded}
    else
      Logger.error("SECURITY ALERT: Path Traversal Detected! Node: #{node_id}, Path: #{relative_path}")
      {:error, :path_traversal_detected}
    end
  end

  @doc """
  Reads an artifact from the workspace.
  Enforces path safety.
  """
  def read_artifact(node_id, relative_path) do
    with {:ok, path} <- safe_path(node_id, relative_path) do
      File.read(path)
    end
  end

  @doc """
  Performs an atomic write with backup.
  """
  def write_atomic(node_id, relative_path, content) do
     with :ok <- check_quota(node_id, byte_size(content)),
          {:ok, dest_path} <- safe_path(node_id, relative_path) do
         # Backup
         if File.exists?(dest_path) do
           root = resolve(node_id)
           history_dir = Path.join(root, ".acn/history")
           # Encure history dir exists (it should, but safe to check)
           File.mkdir_p!(history_dir)

           timestamp = System.system_time(:second)
           backup_name = "#{Path.basename(dest_path)}.#{timestamp}.bak"
           backup_path = Path.join(history_dir, backup_name)

           File.cp(dest_path, backup_path)
         end

         # Atomic Write
         tmp_path = dest_path <> ".tmp"
         File.mkdir_p!(Path.dirname(dest_path))
         File.write!(tmp_path, content)

         case File.rename(tmp_path, dest_path) do
           :ok -> {:ok, dest_path}
           {:error, reason} -> {:error, reason}
         end

    end
  end
  defp check_quota(node_id, new_bytes) do
    root = resolve(node_id)
    # 500MB Limit
    limit = 500 * 1024 * 1024

    # Simple du -sb check (only on linux)
    current_size =
      case System.cmd("du", ["-sb", root], stderr_to_stdout: true) do
        {output, 0} ->
          case Integer.parse(output) do
            {bytes, _} -> bytes
            _ -> 0
          end
        _ -> 0
      end

    if current_size + new_bytes > limit do
      {:error, :quota_exceeded}
    else
      :ok
    end
  end

  @doc """
  Appends content to the end of a file safely.
  """
  def append(node_id, relative_path, content) do
    with :ok <- check_quota(node_id, byte_size(content)),
         {:ok, dest_path} <- safe_path(node_id, relative_path) do
      
      # Optional: Create backup before modification
      backup_file(node_id, dest_path)

      # Append operation
      case File.write(dest_path, content, [:append]) do
        :ok -> {:ok, dest_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Applies a Unified Diff to a physical file atomically.
  """
  def apply_patch(node_id, relative_path, diff_content) do
    with {:ok, dest_path} <- safe_path(node_id, relative_path),
         {:ok, current_content} <- File.read(dest_path) do

      # Use the shared Patch logic (refactored from SpecialistTools)
      case ACN.Core.Utils.Patcher.apply_patch(current_content, diff_content) do
        {:ok, new_content} ->
           # Use write_atomic to save the new version safely
           write_atomic(node_id, relative_path, new_content)
        
        {:error, reason} -> {:error, reason}
      end
    end
  end
  
  defp backup_file(node_id, dest_path) do
    if File.exists?(dest_path) do
      root = resolve(node_id)
      history_dir = Path.join(root, ".acn/history")
      # Ensure history dir exists
      File.mkdir_p!(history_dir)
      
      timestamp = System.system_time(:second)
      backup_name = "#{Path.basename(dest_path)}.#{timestamp}.bak"
      File.cp(dest_path, Path.join(history_dir, backup_name))
    end
  end
end
