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
        "description" =>
          "Builds and pushes a compact artifact record. Source is read from the verified workspace file and is not included in the worksheet.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "fact_text" => %{
              "type" => "string",
              "description" => "A high-level natural language summary of what this artifact does."
            },
            "utility" => %{
              "type" => "string",
              "description" =>
                "Description of the specific utility or value this artifact provides."
            },
            "behaviour" => %{
              "type" => "string",
              "description" =>
                "Description of the expected behavior, state changes, or side effects."
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
            "slot_id" => %{
              "type" => "string",
              "description" => "The specific memory slot ID in the Parent (usually the task ID)."
            },
            "parent_id" => %{
              "type" => "string",
              "description" =>
                "The node ID of the Parent Supervisor. Always use the parent's exact string name (e.g., 'db_models'), never a UUID."
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
          "required" => ["fact_text", "slot_id", "parent_id"]
        }
      }
    end

    def execute(args, env) do
      slot_id = args["slot_id"]
      parent_id = args["parent_id"]

      with {:ok, source} <- load_verified_source(args, env) do
        # 1. Build DBC Struct
        dbc = %DBC{
          id: UUID.uuid4(),
          fact_text: args["fact_text"],
          timestamp: DateTime.utc_now(),
          author_id: "agent_node_#{node()}",
          verifier_id: "judge_bot",
          artifact_hash: args["artifact_hash"] || artifact_hash(source, args),
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

            if local_node_id == "root" and
                 to_string(parent_id) in ["nonode@nohost", "", "nil", "root"] do
              # It's the root node, there is no upstream.
              {:ok, compact_result(dbc)}
            else
              Logger.warning(
                "UpstreamMerge: Could not find node #{parent_id}. Attempting local node fallback."
              )

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
    end

    defp push_to_parent(pid, slot_id, dbc) do
      try do
        case GenServer.call(pid, {:receive_child_artifact, slot_id, dbc, slot_id}, 15_000) do
          :ok -> {:ok, compact_result(dbc)}
          {:error, reason} -> {:error, "Parent Rejected: #{inspect(reason)}"}
          # Handle varied returns
          other -> {:ok, other}
        end
      catch
        :exit, reason -> {:error, "Parent Unreachable (EXIT): #{inspect(reason)}"}
        kind, err -> {:error, "Parent Unreachable (#{kind}): #{inspect(err)}"}
      end
    end

    defp load_verified_source(args, env) do
      path = args["full_path"] || args["fullPath"] || env[:target_path]

      case path do
        path when is_binary(path) and path != "" ->
          node_id = env[:node_id] || "root"

          with {:ok, safe_path} <-
                 ACN.Infrastructure.Workspace.safe_path(node_id, path, env[:working_path]),
               {:ok, source} <- File.read(safe_path) do
            {:ok, source}
          else
            {:error, reason} ->
              {:error, "Could not read verified source file: #{inspect(reason)}"}
          end

        _ ->
          {:ok, ""}
      end
    end

    defp artifact_hash(source, _args) when is_binary(source) and source != "",
      do: :crypto.hash(:sha256, source) |> Base.encode16()

    defp artifact_hash(_source, args) do
      identity = %{
        "fact_text" => args["fact_text"],
        "schema" => args["schema"] || %{},
        "interfaces" => args["interfaces"] || []
      }

      identity
      |> Jason.encode!(sort_keys: true)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16()
    end

    defp compact_result(%DBC{} = dbc), do: %{dbc | source_code: nil}
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
              "description" =>
                "A single, declarative sentence describing the function and intent of the artifact."
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
