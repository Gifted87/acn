defmodule ACN.Tools.Memory do
  @moduledoc """
  Tool wrapper for ACN.Infrastructure.MemoryClient.
  Allows Agents to Semantic Search the General Memory (Cognitive Memory System).
  """
  
  defmodule QueryWisdom do
    @behaviour ACN.Tools.ToolBehaviour
    alias ACN.Infrastructure.MemoryClient
    require Logger

    def definition do
      %{
        "name" => "query_wisdom",
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

    def execute(args, _env) do
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
      end
    end
  end

  defmodule IngestFact do
    @behaviour ACN.Tools.ToolBehaviour
    alias ACN.Infrastructure.MemoryClient
    require Logger

    def definition do
      %{
        "name" => "ingest_fact",
        "description" => "Immortalize a fact or artifact in the Global Memory (ACMS).",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "fact_text" => %{
               "type" => "string",
               "description" => "A descriptive, declarative title or summary of the artifact."
            },
            "interfaces" => %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "description" => "List of public interfaces/functionalities."
            },
            "schema" => %{
               "type" => "object",
               "description" => "Data structure definition."
            }
          },
          "required" => ["fact_text"]
        }
      }
    end

    def execute(args, _env) do
      fact = args["fact_text"]
      
      # Build Real DBC for ingestion
      dbc = %ACN.Core.Artifacts.DBC{
        id: UUID.uuid4(),
        fact_text: fact,
        author_id: "judge_bot_archivist",
        timestamp: DateTime.utc_now(),
        verifier_id: "judge_bot",
        artifact_hash: :crypto.hash(:sha256, fact) |> Base.encode16(),
        provenance_data: %{
          interfaces: args["interfaces"] || [],
          schema: args["schema"] || %{},
          node: node()
        }
      }

      case MemoryClient.ingest(dbc) do
        {:ok, node_id} -> "Fact ingested into ACMS. Node ID: #{node_id}"
        {:error, reason} -> "Ingestion Failed: #{inspect(reason)}"
      end
    end
  end
  defmodule ProbeLattice do
    @behaviour ACN.Tools.ToolBehaviour
    alias ACN.Core.LatticeRegistry
    require Logger

    def definition do
      %{
        "name" => "probe_lattice",
        "description" => "Discover capabilities, modules, and file paths in the ACN. Use this to find dependencies or existing code.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Search query (e.g. 'Authentication module', 'lib/user/auth/login.ex')"
            }
          },
          "required" => ["query"]
        }
      }
    end

    def execute(args, _env) do
      query = args["query"]
      
      # 1. Try Exact Path Lookup
      path_res = LatticeRegistry.lookup_by_path(query)
      
      # 2. Semantic Search
      search_res = LatticeRegistry.search(query)
      
      # Combine Results
      report = []
      
      report = 
        case path_res do
          {:ok, reg} -> report ++ ["EXACT PATH MATCH: Module #{reg.module} at #{reg.path}"]
          _ -> report
        end
        
      report = 
        case search_res do
          {:ok, results} -> 
            sem_results = Enum.map(results, fn r -> "- Module #{r.module} at #{r.path} (Similarity: #{Float.round(r.score, 2)})" end)
            report ++ ["SEMANTIC MATCHES:"] ++ sem_results
          _ -> report
        end
        
      if Enum.empty?(report) do
        "No matching capabilities found in the Lattice."
      else
        Enum.join(report, "\n")
      end
    end
  end
end
