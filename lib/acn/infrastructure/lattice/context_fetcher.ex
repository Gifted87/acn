defmodule ACN.Infrastructure.Lattice.ContextFetcher do
  @moduledoc """
  Hydrates the agent's context by fetching data from ancestors in parallel.
  """
  require Logger
  alias ACN.Infrastructure.Lattice.{RPC, Ancestry, NodeInfo}
  alias ACN.Core.Worksheet

  @export_slot "public_export"

  def fetch_deep_context(%Ancestry{} = ancestry) do
    # 1. Define Targets
    targets = [
      {:generation_1, ancestry.parent},
      {:generation_2, ancestry.grandparent},
      {:generation_3, ancestry.great_grandparent}
    ]
    |> Enum.filter(fn {_, info} -> not is_nil(info) end)

    # 2. Parallel Fetch
    results = 
      targets
      |> Task.async_stream(fn {gen, info} -> 
           {gen, fetch_from_node(info)}
         end, timeout: 6000) # Slightly > RPC timeout
      |> Enum.map(fn 
           {:ok, result} -> result
           {:exit, reason} -> 
             Logger.error("ContextFetch Task Exit: #{inspect(reason)}")
             {:error, :task_exit}
         end)
      |> Map.new()

    # 3. Validate Critical Path (Parent)
    case Map.get(results, :generation_1) do
      {:ok, _ws} -> 
        # Parent OK. Others can be errors (result map contains tuples).
        # We need to unwrap valid ones and fill errors for others.
         unwrap_results(results)
         
      {:error, reason} ->
         raise "CRITICAL: Failed to fetch context from Parent! Reason: #{inspect(reason)}"
      
      nil ->
         # Genesis case (no parent)?
         if is_nil(ancestry.parent) do
           %{generation_1: Worksheet.new()}
         else
           raise "CRITICAL: Logic Error. Parent exists but not fetched?"
         end
    end
  end

  defp fetch_from_node(%NodeInfo{pid: pid, id: id}) do
    Logger.debug("Fetching context from #{id} (#{inspect(pid)})")
    case RPC.fast_call(pid, {:read_worksheet, @export_slot}) do
      {:ok, {:ok, %Worksheet.Slot{content: content}}} -> {:ok, content}
      {:ok, {:error, :not_found}} -> {:ok, Worksheet.new()} # Valid but empty
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp unwrap_results(results) do
    Enum.into(results, %{}, fn {gen, res} -> 
      case res do
        {:ok, ws} -> {gen, ws}
        {:error, _} -> {gen, :incomplete} # Graceful degradation for GP/GGP
      end
    end)
  end
end
