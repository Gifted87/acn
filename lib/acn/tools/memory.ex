defmodule ACN.Tools.Memory do
  @moduledoc """
  Tool wrapper for ACN.Infrastructure.MemoryClient.
  Allows Agents to Semantic Search the General Memory (Vector DB).
  """
  
  defmodule GenerateQuery do
    @behaviour ACN.Tools.ToolBehaviour
    alias ACN.Infrastructure.MemoryClient
    require Logger

    def definition do
      %{
        "name" => "generate_gm_query",
        "description" => "Search the General Memory (ACMS) for historical facts, code patterns, or warnings.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query_text" => %{
              "type" => "string",
              "description" => "The semantic search query (e.g., 'Elixir GenServer best practices')"
            },
            "rationale" => %{
              "type" => "string",
              "description" => "Why this query is relevant to the current task."
            }
          },
          "required" => ["query_text"]
        }
      }
    end

    def execute(args) do
      # Handle potential LLM parameter hallucination
      query = args["query_text"] || args["query"]

      if is_nil(query) or String.trim(query) == "" do
        "Error: 'query_text' argument is required and cannot be empty."
      else
        Logger.debug("Tool Memory: Querying ACMS for '#{query}'")

      case MemoryClient.query(query) do
        {:ok, results} when is_list(results) ->
           if Enum.empty?(results) do
             "No relevant memories found."
           else
             results
             |> Enum.take(5) # Top 5
             |> Enum.map(fn r -> 
                # Handle struct or map
                text = Map.get(r, :fact_text) || Map.get(r, "fact_text") || "Unknown"
                score = Map.get(r, :score) || Map.get(r, "score") || 0.0
                "- #{text} (Score: #{Float.round(score, 2)})" 
             end)
             |> Enum.join("\n")
           end
           
        {:error, reason} ->
           "Memory Search Failed: #{inspect(reason)}"
           
        _ -> "Unexpected response from MemoryClient"
      end
      end  # Close the if/else block
    end
  end
end
