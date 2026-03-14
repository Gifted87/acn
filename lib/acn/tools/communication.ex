defmodule ACN.Tools.Communication.DispatchIntent do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "dispatch_intent",
      "description" => "Dispatches the classified user intent to the appropriate agent.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => ["query", "command", "garbage"],
            "description" => "Classification of the input type."
          },
          "target" => %{
            "type" => "string",
            "enum" => ["controller", "specialist", "validator", "live_wire", "none"],
            "description" => "The destination agent for this message."
          },
          "intent" => %{
            "type" => "string",
            "description" => "The specific programmatic intention detected."
          },
          "confidence" => %{
            "type" => "number",
            "minimum" => 0.0,
            "maximum" => 1.0,
            "description" => "Probability score (0-1)."
          }
        },
        "required" => ["type", "target", "intent", "confidence"]
      }
    }
  end

  def execute(args, _context) do
    # Logic handled by Messenger Dispatcher
    {:ok, "Intent dispatched to #{args["target"]}."}
  end
end
defmodule ACN.Tools.Communication.SubmitChronicle do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "submit_chronicle",
      "description" => "Submits a compressed, human-readable summary of system events.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "summary" => %{
            "type" => "string",
            "description" => "A single line status update (max 100 chars)."
          }
        },
        "required" => ["summary"]
      }
    }
  end

  require Logger
  alias ACN.Core.NodeRegistry

  def execute(args, _context) do
    summary = args["summary"]

    # Resolve Node ID for topic
    node_id =
      case NodeRegistry.lookup(:supervisor) do
        {:ok, %{pid: pid}} ->
           try do
             GenServer.call(pid, :get_node_id, 1000)
           catch
             _, _ -> "root"
           end
        _ -> "root"
      end

    Logger.info("Tool: SubmitChronicle broadcasting: #{summary}")
    Phoenix.PubSub.broadcast(ACN.PubSub, "acn:dashboard:#{node_id}", {:narrative_update, summary})

    {:ok, "Chronicle submitted."}
  end
end
