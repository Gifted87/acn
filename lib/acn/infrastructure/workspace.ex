defmodule ACN.Infrastructure.Workspace do
  @moduledoc """
  Manages filesystem isolation for ACN Nodes.
  Enforces that nodes can only write within their assigned jail.
  Handles atomic writes and backups.
  """
  require Logger
  alias ACN.Observability.Emitter

  # Default root if not configured
  @default_root "tmp/acn_workspaces"

  def root_path do
     Application.get_env(:acn, :workspace_root, @default_root)
     |> Path.expand()
  end

  @doc """
  Resolves the absolute path for a node's workspace.
  Each node gets its own isolated folder: workspace_root/node_id/
  
  This enables task isolation where each node's file operations are scoped
  to its own directory, preventing conflicts and enabling parallel execution.
  
  ## Examples
  
      iex> resolve("genesis_root_abc")
      "tmp/acn_workspaces/genesis_root_abc/"
      
      iex> resolve("task_xyz")
      "tmp/acn_workspaces/task_xyz/"
  """
  def resolve(node_id) do
    str_id = to_string(node_id)
    if Path.type(str_id) == :absolute do
      str_id
    else
      Path.join(root_path(), str_id)
    end
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

  def safe_path(node_id, relative_path, working_path \\ nil) do
    # Global absolute root for all ACN workspaces
    global_root = root_path()
    
    # 1. Determine the effective jail root.
    # If working_path is provided and is inside global_root, use it as the boundary.
    # IMPORTANT: working_path may be a FILE path (e.g. the legislator target_path).
    # Always normalise to a directory so sibling writes are not falsely rejected.
    node_root = resolve(node_id)
    
    jail_root =
      if working_path && String.starts_with?(working_path, global_root) do
        # If it's a regular file on disk, use its parent dir as the jail.
        # If it doesn't exist yet (pre-creation), also use dirname so that both
        # the file itself and siblings in the same directory are within bounds.
        if File.regular?(working_path) do
          Path.dirname(working_path)
        else
          # If it looks like a file (has an extension) treat it as file path too
          if Path.extname(working_path) != "" do
            Path.dirname(working_path)
          else
            working_path
          end
        end
      else
        node_root
      end
    
    # 2. Resolve the target path
    expanded = 
      if Path.type(relative_path) == :absolute do
         Path.expand(relative_path)
      else
         Path.expand(relative_path, jail_root)
      end
    
    # 3. Security Boundary Check
    if String.starts_with?(expanded, jail_root) do
       {:ok, expanded}
    else
       Logger.error("Workspace: SPATIAL JAIL VIOLATION. Attempted to access #{expanded} outside of #{jail_root}")
       {:error, :spatial_violation}
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
  def write_atomic(node_id, relative_path, content, working_path \\ nil) do
     with :ok <- check_quota(node_id, byte_size(content)),
          # Fix 4C: Pass the working_path into safe_path to enforce strictly bounded spatial jailing
          {:ok, dest_path} <- safe_path(node_id, relative_path, working_path) do
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
           :ok -> 
             # HSG Layer 4: Spatial write & Vector Emission
             # For a full file rewrite, the diff is the whole new file content 
             # (or we could compute a real diff if we read the old, but for atomic overwrite, usually just capture the new content)
             diff_text = "--- ATOMIC OVERWRITE ---\n" <> String.slice(content, 0, 5000)
             
             # Calculate checksums
             checksum_after = :crypto.hash(:sha256, content) |> Base.encode16()
             # Normally we'd calculate checksum_before from backup, but we emit raw intent here
             
             Emitter.push_physical(%{
               file_path: relative_path,
               operation: :write,
               unified_diff: diff_text,
               checksum_before: nil,
               checksum_after: checksum_after
             })
             
             {:ok, dest_path}
           {:error, reason} -> {:error, reason}
         end

    end
  end
  def copy_artifact(node_id, source_rel, dest_rel) do
    with {:ok, source_path} <- safe_path(node_id, source_rel),
         {:ok, dest_path} <- safe_path(node_id, dest_rel) do
      
      File.mkdir_p!(Path.dirname(dest_path))
      
      case File.cp(source_path, dest_path) do
        :ok -> {:ok, dest_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Touches a file (creates if not exists, updates mtime).
  """
  def touch(node_id, relative_path, working_path \\ nil) do
    with {:ok, dest_path} <- safe_path(node_id, relative_path, working_path) do
       # Ensure parent exists
       File.mkdir_p!(Path.dirname(dest_path))
       
       case File.touch(dest_path) do
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
           result = write_atomic(node_id, relative_path, new_content)
           
           # HSG Layer 4: Spatial write & Vector Emission for Patch
           checksum_before = :crypto.hash(:sha256, current_content) |> Base.encode16()
           checksum_after = :crypto.hash(:sha256, new_content) |> Base.encode16()
           
           Emitter.push_physical(%{
             file_path: relative_path,
             operation: :patch,
             unified_diff: diff_content,
             checksum_before: checksum_before,
             checksum_after: checksum_after
           })
           
           result
        
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
