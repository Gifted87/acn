defmodule ACN.Tools.Governance.CompleteConsolidation do
  @moduledoc "Marks an intermediary node's repaired and verified work complete."
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      "name" => "complete_consolidation",
      "description" => "Terminal action marking this intermediary node's verified and repaired workspace complete.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "summary" => %{"type" => "string", "description" => "What was verified and repaired."}
        },
        "required" => ["summary"]
      }
    }
  end

  @impl true
  def execute(args, _context) do
    {:ok, "Consolidation complete: #{args["summary"] || args[:summary] || "verified"}"}
  end
end
