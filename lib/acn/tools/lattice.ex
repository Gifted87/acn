defmodule ACN.Tools.Lattice do
  @moduledoc """
  Tools for Distributed Lattice Communication (Parent-Child).
  """

  defmodule UpstreamMerge do
    @behaviour ACN.Tools.ToolBehaviour
    require Logger
    alias ACN.Core.NodeRegistry

    alias ACN.Core.Artifacts.DBC

    def definition do
      %{
        "name" => "upstream_merge",
        "description" => "Builds and pushes a finalized Digital Birth Certificate (DBC) including technical summaries and source code to the Parent Node and ACMS.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "fact_text" => %{
              "type" => "string",
              "description" => "A high-level natural language summary of what this artifact does."
            },
            "utility" => %{
              "type" => "string",
              "description" => "Description of the specific utility or value this artifact provides."
            },
            "behaviour" => %{
              "type" => "string",
              "description" => "Description of the expected behavior, state changes, or side effects."
            },
            "interfaces" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of public functions, parameters, and return types."
            },
            "schema" => %{
              "type" => "object",
              "description" => "Data structure, types, or configuration used by this artifact."
            },
            "source_code" => %{
              "type" => "string",
              "description" => "The final, verified source code content."
            },
            "slot_id" => %{
              "type" => "string",
              "description" => "The specific memory slot ID in the Parent (usually the task ID)."
            },
            "parent_id" => %{
              "type" => "string",
              "description" => "The node ID of the Parent Supervisor. Always use the parent's exact string name (e.g., 'db_models'), never a UUID."
            },
            "artifact_hash" => %{
               "type" => "string",
               "description" => "Optional SHA256 hash of the artifact content."
            },
            "full_path" => %{
               "type" => "string",
               "description" => "The absolute path to the written file."
            },
            "filename" => %{
               "type" => "string",
               "description" => "The basename of the written file."
            }
          },
          "required" => ["fact_text", "slot_id", "parent_id", "source_code"]
        }
      }
    end

    def execute(args, env) do
      slot_id = args["slot_id"]
      parent_id = args["parent_id"]
      source = args["source_code"] || ""
      
      # 1. Build DBC Struct
      dbc = %DBC{
        id: UUID.uuid4(),
        fact_text: args["fact_text"],
        timestamp: DateTime.utc_now(),
        author_id: "agent_node_#{node()}",
        verifier_id: "judge_bot",
        artifact_hash: args["artifact_hash"] || (:crypto.hash(:sha256, source) |> Base.encode16()),
        source_code: source,
        full_path: args["full_path"],
        filename: args["filename"],
        provenance_data: %{
          interfaces: args["interfaces"] || [],
          schema: args["schema"] || %{},
          utility: args["utility"] || "N/A",
          behaviour: args["behaviour"] || "N/A",
          node: node()
        }
      }

      Logger.info("Tool Lattice: Pushing DBC to Parent #{parent_id} (Slot: #{slot_id}).")

      # 2. Resolve Parent and Push to Worksheet (Parent will handle ACMS ingestion)
      lookup_result = NodeRegistry.lookup(parent_id)

      case lookup_result do
        {:ok, %{pid: pid}} ->
          push_to_parent(pid, slot_id, dbc)
        _ -> 
           local_node_id = Map.get(env, :node_id, "root")
           
           if local_node_id == "root" and to_string(parent_id) in ["nonode@nohost", "", "nil", "root"] do
             # It's the root node, there is no upstream. 
             {:ok, dbc}
           else
             Logger.warning("UpstreamMerge: Could not find node #{parent_id}. Attempting local node fallback.")
             case NodeRegistry.lookup(local_node_id) do
               {:ok, %{pid: pid}} ->
                 push_to_parent(pid, slot_id, dbc)
               _ ->
                  # Last ditch: try "root"
                  case NodeRegistry.lookup("root") do
                    {:ok, %{pid: pid}} -> push_to_parent(pid, slot_id, dbc)
                    _ -> {:error, "Parent #{parent_id} Not Found and local fallback failed."}
                  end
             end
           end
      end
    end

    defp push_to_parent(pid, slot_id, dbc) do
      try do
        case GenServer.call(pid, {:receive_child_artifact, slot_id, dbc, slot_id}, 15_000) do
          :ok -> {:ok, dbc}
          {:error, reason} -> {:error, "Parent Rejected: #{inspect(reason)}"}
          other -> {:ok, other} # Handle varied returns
        end
      catch
        :exit, reason -> {:error, "Parent Unreachable (EXIT): #{inspect(reason)}"}
        kind, err -> {:error, "Parent Unreachable (#{kind}): #{inspect(err)}"}
      end
    end
  end

  defmodule SubmitFact do
    @behaviour ACN.Tools.ToolBehaviour

    def definition do
      %{
        "name" => "submit_fact",
        "description" => "Submits a semantic fact (declarative sentence) about a task result.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "fact" => %{
              "type" => "string",
              "description" => "A single, declarative sentence describing the function and intent of the artifact."
            }
          },
          "required" => ["fact"]
        }
      }
    end

    def execute(_args, _context) do
      {:ok, "Fact submitted."}
    end
  end
end
