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
          },
          "path" => %{
             "type" => "string",
             "description" => "Optional: The absolute path for the node's workspace (used primarily by root nodes)."
          }
        },
        "required" => ["identity"]
      }
    }
  end

  def execute(params, _env) do
    identity_str = params["identity"]
    path = params["path"]

    identity = 
      case String.upcase(identity_str) do
        "LEAF" -> :leaf
        "INTERMEDIATE" -> :intermediate
        _ -> :leaf # Default safety
      end
      
    Logger.warning("🔧 Tool executing: Setting Node Identity to #{inspect(identity)} (path: #{inspect(path)})")
    
    # Cast back to the Agent to update state
    GenServer.cast(self(), {:set_identity, identity, path})
    
    {:ok, "Identity set to #{identity_str}. Proceeding to Morphic State transition."}
  end
end
