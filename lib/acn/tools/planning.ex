defmodule ACN.Tools.Planning do
  @moduledoc """
  Tools for Graph Manipulation by the TaskManager.
  These tools are designed to be run INSIDE the TaskManager process (process dictionary/self).
  """

  defmodule AddNode do
    @behaviour ACN.Tools.ToolBehaviour
    require Logger

    def definition do
      %{
        "name" => "add_plan_node",
        "description" => "Adds a task node to the execution graph. Use this to decompose the goal.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Short, unique name for the task (e.g., 'build_database')"
            },
            "description" => %{
              "type" => "string",
              "description" => "Detailed instruction of what this task must achieve."
            },
            "type" => %{
              "type" => "string",
              "enum" => ["leaf", "intermediate"],
              "description" => "Leaf = Atomic/Executes Code. Intermediate = Sub-Manager/Delegates."
            },
            "output_directive" => %{
               "type" => "string",
               "description" => "Explicit instruction on what this task must produce (e.g., 'A filepath to the compiled binary', 'The implementation of Foo module'). This dictates the artifact contract."
            }
          },
          "required" => ["name", "description", "type", "output_directive"]
        }
      }
    end

    def execute(args) do
      # 1. Generate UUID
      # "Behavior: ... generate a UUID ... and return it to the LLM context."
      
      uuid = args["name"] 
      # Simplification: Use the slug/name provided by LLM as ID.
      # This ensures stability in Phase 2 (Linker) without complex memory.
      
      # 2. Update GenServer State (via Cast)
      # We assume self() is the TaskManager GenServer
      GenServer.cast(self(), {:add_node, uuid, args})

      Logger.debug("Tool AddNode: Queued #{uuid}")

      {:ok, "Node '#{uuid}' added to plan."}
    end
  end

  defmodule LinkDependency do
    @behaviour ACN.Tools.ToolBehaviour
    require Logger

    def definition do
      %{
        "name" => "link_dependency",
        "description" => "Defines a dependency: Provider must finish BEFORE Consumer starts.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "provider_task_id" => %{
              "type" => "string",
              "description" => "The task that produces data (run first)."
            },
            "consumer_task_id" => %{
              "type" => "string",
              "description" => "The task that needs the data (run second)."
            }
          },
          "required" => ["provider_task_id", "consumer_task_id"]
        }
      }
    end

    def execute(args) do
      provider = args["provider_task_id"]
      consumer = args["consumer_task_id"]

      cond do
        is_nil(provider) or is_nil(consumer) ->
           {:error, "Missing provider or consumer task ID."}
        String.trim(provider) == "" or String.trim(consumer) == "" ->
           {:error, "Provider or consumer task ID cannot be empty."}
        provider == consumer ->
           {:error, "Cannot link task to itself (Cycle detected)."}
        true ->
           GenServer.cast(self(), {:add_dependency, provider, consumer})
           Logger.debug("Tool LinkDependency: Queued #{provider} -> #{consumer}")
           {:ok, "Dependency linked: #{provider} -> #{consumer}"}
      end
    end
  end
end
