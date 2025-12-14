defmodule ACN.Tools.Supervisor.Identity do
  @behaviour ACN.Tools.ToolBehaviour
  require Logger

  def definition do
    %{
      "name" => "set_node_identity",
      "description" => "Sets the identity of the node (LEAF or INTERMEDIATE).",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "identity" => %{
             "type" => "string",
             "enum" => ["LEAF", "INTERMEDIATE"],
             "description" => "The determined identity based on task complexity."
          }
        },
        "required" => ["identity"]
      }
    }
  end

  def execute(%{"identity" => identity_str}) do
    identity = 
      case String.upcase(identity_str) do
        "LEAF" -> :leaf
        "INTERMEDIATE" -> :intermediate
        _ -> :leaf # Default safety
      end
      
    Logger.info("Tool: Setting Node Identity to #{inspect(identity)}")
    
    # Cast back to the Agent to update state
    GenServer.cast(self(), {:set_identity, identity})
    
    {:ok, "Identity set to #{identity_str}. Proceeding to Morphic State transition."}
  end
end
