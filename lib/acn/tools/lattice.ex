defmodule ACN.Tools.Lattice do
  @moduledoc """
  Tools for Distributed Lattice Communication (Parent-Child).
  """

  defmodule UpstreamMerge do
    @behaviour ACN.Tools.ToolBehaviour
    require Logger
    alias ACN.Core.NodeRegistry

    def definition do
      %{
        "name" => "upstream_merge",
        "description" => "Push a finalized Digital Birth Certificate (DBC) to the Parent Node's memory slot.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "dbc" => %{
              "type" => "object",
              "description" => "The Digital Birth Certificate struct."
            },
            "slot_id" => %{
              "type" => "string",
              "description" => "The specific memory slot ID in the Parent."
            },
            "parent_id" => %{
              "type" => "string",
              "description" => "The node ID of the Parent Supervisor."
            }
          },
          "required" => ["dbc", "slot_id", "parent_id"]
        }
      }
    end

    def execute(args) do
      # Note: args keys are strings
      dbc = args["dbc"]
      slot_id = args["slot_id"]
      parent_id = args["parent_id"]

      Logger.info("Tool Lattice: Pushing artifact to Parent #{parent_id} (Slot: #{slot_id})")

      # 1. Locate Parent
      # NodeRegistry.lookup handles local vs distributed logic if implemented correctly
      case NodeRegistry.lookup(parent_id) do
        {:ok, %{pid: pid}} ->
           # 2. Remote Push (Call for reliability)
           # We use GenServer.call to ensure the parent accepted it before we shutdown.
           try do
             # Message format: {:receive_child_artifact, slot_id, dbc, child_node_id}
             # We assume child_node_id is self() or provided? 
             # Supervisor expects: {:receive_child_artifact, slot_id, artifact, child_id}
             # We'll retrieve our own ID or pass it?
             # Let's pass the pid for now as child_id, or better, the node name if available.
             # The usage in Supervisor `handle_cast` used `child_id`.
             # Let's use `node()` or `self()`. `self()` is a PID.
             # Ideally we pass the ID string.
             # Let's trust the caller (Synthesizer) to put author_id in DBC.
             # But the message signature requires `child_id` as 4th element.
             
             # We will use `self()` as the source identity for the call.
             
             case GenServer.call(pid, {:receive_child_artifact, slot_id, dbc, self()}) do
               :ok -> "Delivered to Parent"
               {:error, reason} -> "Parent Rejected: #{inspect(reason)}"
             end
           catch
             :exit, reason -> "Parent Unreachable (EXIT): #{inspect(reason)}"
           end

        _ -> "Parent Not Found in Registry"
      end
    end
  end
end
