defmodule ACN.Core.Utils.Patcher do
  @moduledoc """
  Shared logic for applying Unified Diffs.
  """
  require Logger

  def apply_patch(content, diff) do
    lines = String.split(content, "\n")
    
    # Simple Unified Diff Parser & Applier
    # 1. Parse Hunks
    try do
      hunks = parse_hunks(diff)
      # 2. Apply Hunks
      final_lines = apply_hunks(lines, hunks)
      {:ok, Enum.join(final_lines, "\n")}
    rescue
      e -> {:error, "Patch Logic Error: #{inspect(e)}"}
    end
  end

  defp parse_hunks(diff) do
    diff_lines = String.split(diff, "\n")
    
    # Filter header
    body = Enum.drop_while(diff_lines, fn l -> 
       String.starts_with?(l, "---") or String.starts_with?(l, "+++") or String.starts_with?(l, "Index:") 
    end)
    
    chunk_hunks(body, [])
  end

  defp chunk_hunks([], acc), do: Enum.reverse(acc)
  defp chunk_hunks([head | tail], acc) do
    if String.starts_with?(head, "@@") do
       # Start of new hunk
       {hunk_lines, rest} = Enum.split_while(tail, fn l -> !String.starts_with?(l, "@@") end)
       chunk_hunks(rest, [{head, hunk_lines} | acc])
    else
       # Skip garbage before first hunk?
       chunk_hunks(tail, acc)
    end
  end

  defp apply_hunks(original_lines, hunks) do
    # This is a simplified applier aka "fuzzy patch" or just specific implementation
    # We iterate hunks. For each hunk, we find the "context" in original lines.
    # Note: Unified diff line numbers (in @@) are 1-based.
    
    Enum.reduce(hunks, original_lines, fn {header, changes}, current_lines ->
       # Parse header @@ -Start,Count +Start,Count @@
       # We actually ignore the numbers often in naive patchers and rely on Context Matching
       # because line numbers shift.
       
       # Naive Context Matching:
       # Verify the context lines (starting with ' ') match a block in current_lines.
       # Verify the deleted lines (starting with '-') match the lines inside that block.
       
       # Extract the "Old Block" pattern to find
       pattern = 
         changes 
         |> Enum.filter(fn l -> String.starts_with?(l, " ") or String.starts_with?(l, "-") end)
         |> Enum.map(fn 
              " " <> line -> line
              "-" <> line -> line
              l -> l # Should not happen if well formed
            end)
            
       # Find where this pattern exists in current_lines
       case find_sublist_index(current_lines, pattern) do
         nil -> 
           raise "Hunk context not found. Header: #{header}"
         index ->
           # We found the block at 'index'. Now we reconstruct it using the NEW lines.
           # New lines come from ' ' and '+' in changes.
           replacement_block = 
             changes
             |> Enum.filter(fn l -> String.starts_with?(l, " ") or String.starts_with?(l, "+") end)
             |> Enum.map(fn 
                " " <> line -> line
                "+" <> line -> line
                l -> l 
             end)
             
           # Replace slice
           replace_sublist(current_lines, index, length(pattern), replacement_block)
       end
    end)
  end

  defp find_sublist_index(list, sublist) do
    # Slow naive search
    sub_len = length(sublist)
    limit = length(list) - sub_len
    
    if limit < 0 do
      nil
    else
      Enum.find_index(0..limit, fn i ->
        slice = Enum.slice(list, i, sub_len)
        slice == sublist
      end)
    end
  end

  defp replace_sublist(list, start_index, length_to_remove, new_items) do
    pre = Enum.take(list, start_index)
    post = Enum.drop(list, start_index + length_to_remove)
    pre ++ new_items ++ post
  end
end
