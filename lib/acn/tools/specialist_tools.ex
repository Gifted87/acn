defmodule ACN.Tools.SpecialistTools do
  @moduledoc """
  Defines tools for the Specialist's Cognitive Loop.
  Operates on the Virtual Worksheet (RAM).
  """
  require Logger

  @doc "Returns OpenAI Tool Definitions"
  def definitions do
    [
      %{
        type: "function",
        function: %{
          name: "worksheet_write",
          description: "Overwrites a file in the virtual workspace (RAM). Use for creating new files.",
          parameters: %{
            type: "object",
            properties: %{
              filename: %{type: "string", description: "Relative path (e.g. lib/foo.ex)"},
              content: %{type: "string", description: "Full file content"}
            },
            required: ["filename", "content"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "worksheet_read",
          description: "Reads a file from the virtual workspace.",
          parameters: %{
            type: "object",
            properties: %{
              filename: %{type: "string"}
            },
            required: ["filename"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "worksheet_patch",
          description: "Patches a file using a Unified Diff. Use for editing existing files.",
          parameters: %{
            type: "object",
            properties: %{
              filename: %{type: "string"},
              diff: %{type: "string", description: "Unified diff string"}
            },
            required: ["filename", "diff"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "lattice_refresh_context",
          description: "Fetches the latest ancestral data from the Lattice (Parent Node) and updates the local Read-Only memory.",
          parameters: %{
            type: "object",
            properties: %{},
            required: []
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "submit_draft",
          description: "Submits the current state of the worksheet to the Controller.",
          parameters: %{
            type: "object",
            properties: %{},
            required: []
          }
        }
      }
    ]
  end

  @doc """
  Executes a tool call.
  Returns {:ok, output, new_worksheet} or {:error, reason}.
  """
  def execute(call, worksheet, context \\ %ACN.Core.Artifacts.ImmutableContext{})

  def execute(%{"name" => "worksheet_write", "arguments" => args}, worksheet, context) do
     filename = args["filename"]
     content = args["content"]

     # ENFORCEMENT 2: Write Restricted to Local Scope
     # Check if filename exists in Ancestral Memory (Read-Only)
     if Map.has_key?(context.ancestral_memory, filename) do
        {:ok, "Permission Denied: Cannot overwrite file '#{filename}' belonging to an Ancestor Node.", worksheet}
     else
        # Update Worksheet
        new_worksheet = Map.put(worksheet, filename, content)
        {:ok, "Wrote #{byte_size(content)} bytes to #{filename}", new_worksheet}
     end
  end

  def execute(%{"name" => "worksheet_read", "arguments" => args}, worksheet, context) do
     filename = args["filename"]
     
     # ENFORCEMENT 1: Read Priority (Local -> Ancestral)
     case Map.get(worksheet, filename) do
       nil -> 
          # Check Ancestral Memory
          case Map.get(context.ancestral_memory, filename) do
             nil -> {:ok, "Error: File not found in Local or Ancestral memory.", worksheet}
             ancestral_content -> {:ok, ancestral_content, worksheet}
          end
       content -> {:ok, content, worksheet}
     end
  end


  def execute(%{"name" => "lattice_refresh_context", "arguments" => _args}, worksheet, _context) do
    # 1. Identify Parent Logic
    # We retrieve parent from Supervisor via Registry lookup (assuming local supervisor is Genesis)
    parent_id = 
       case GenServer.call(ACN.Core.NodeRegistry.via_tuple(:supervisor, :supervisor), :get_parent_id) do
          {:ok, pid} -> pid
          _ -> nil
       end
       
    if parent_id do
       case ACN.Infrastructure.Lattice.fetch_ancestral_data(parent_id) do
          {:ok, remote_data} ->
             # Merge Parent artifacts into Worksheet.
             # Ancestral Memory takes precedence for *new* data, but we merge into local RAM.
             new_artifacts = remote_data.ancestral_memory || %{}
             count = map_size(new_artifacts)
             
             # Merge: Parent artifacts (new_artifacts) + Local (worksheet)
             # Map.merge(new, local) -> local wins collisions.
             # This preserves local work but fills in missing dependencies from parent.
             updated_worksheet = Map.merge(new_artifacts, worksheet)
             
             {:ok, "Lattice Refresh Complete. Synced #{count} artifacts from Parent.", updated_worksheet}
             
          {:error, reason} ->
             {:ok, "Lattice Refresh Failed: #{inspect(reason)}", worksheet}
       end
    else
       {:ok, "Error: Could not identify Parent Node.", worksheet}
    end
  end

  def execute(%{"name" => "worksheet_patch", "arguments" => args}, worksheet, context) do
    filename = args["filename"]
    diff = args["diff"]

    # Patching requires reading first -> Use read logic
    original_content = 
       case Map.get(worksheet, filename) do
         nil -> Map.get(context.ancestral_memory, filename)
         c -> c
       end

    case original_content do
      nil -> {:ok, "Error: File to patch not found: #{filename}", worksheet}
      content ->
        # If content came from Ancestor, we MUST NOT modify it in place if we treat it as read-only.
        # But 'worksheet_patch' implies creating a NEW version in local worksheet.
        # So we patch 'content' and save to 'worksheet[filename]'.
        # BUT wait -> Write Rule says we cannot overwrite ancestor file.
        # If we patch an ancestor file, we are creating a local fork?
        # User spec says: "writes are only allowed to the local VirtualWorksheet. Attempts to write to paths belonging to Ancestors must return a 'Permission Denied' tool error."
        # This implies we cannot even 'fork' it if the path is same.
        # So patching an ancestor file is forbidden unless we rename it?
        # Or maybe "paths belonging to Ancestors" means "modifying the upstream state".
        # But here valid "worksheet_write" puts it in local map.
        # If I patch `lib/foo.ex` (ancestor), result goes into `worksheet["lib/foo.ex"]`.
        # `worksheet_write` above blocks this if key exists in ancestor.
        # So `worksheet_patch` should also block if target is ancestor.
        
        if Map.has_key?(context.ancestral_memory, filename) do
           {:ok, "Permission Denied: Cannot patch/overwrite ancestor file '#{filename}'.", worksheet}
        else
           # It's a local file.
             case ACN.Core.Utils.Patcher.apply_patch(content, diff) do
              {:ok, new_content} ->
                 new_worksheet = Map.put(worksheet, filename, new_content)
                 {:ok, "Patch applied successfully.", new_worksheet}
              {:error, reason} ->
                 {:ok, "Patch Failed: #{reason}", worksheet}
            end
        end
    end
  end

  def execute(%{"name" => "submit_draft", "arguments" => _args}, worksheet, _context) do
     {:ok, "Draft Submitted", worksheet, :terminate}
     # Special tag :terminate to signal loop break
  end

  def execute(unknown, worksheet, _context) do
     {:ok, "Error: Unknown tool #{inspect(unknown)}", worksheet}
  end
end
