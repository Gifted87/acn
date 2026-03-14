defmodule ACN.Tools.Governance.SubmitLegislation do
  @moduledoc """
  Tool for the Legislator to submit the synthesized RuleSheet.
  """
  @behaviour ACN.Tools.ToolBehaviour
  require Logger

  @impl true
  def definition do
    %{
      "name" => "submit_legislation",
      "description" => "Submits the final synthesized RuleSheet (list of requirements and constraints).",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "rules" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "A list of strings defining strict functional requirements and constraints."
          }
        },
        "required" => ["rules"]
      }
    }
  end

  @impl true
  def execute(args, _context) do
    rules = args["rules"] || []
    if rules == [], do: Logger.warning("SubmitLegislation: Received EMPTY rules list!")
    {:ok, "Legislation submitted: #{length(rules)} rules generated."}
  end
end

defmodule ACN.Tools.Governance.SubmitVerdict do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "submit_verdict",
      "description" => "Submits the final verdict (APPROVED or REJECTED) for a draft and its reasoning.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{
            "type" => "string",
            "enum" => ["APPROVED", "REJECTED"],
            "description" => "The final decision on the draft."
          },
          "reason" => %{
            "type" => "string",
            "description" => "Explanation for the decision, citing specific rules if rejected."
          }
        },
        "required" => ["verdict", "reason"]
      }
    }
  end

  def execute(args, _context) do
    {:ok, "Verdict submitted: #{args["verdict"]}"}
  end
end

defmodule ACN.Tools.Governance.SubmitMediation do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "submit_mediation",
      "description" => "Submits the resolved list of rules after mediation.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "rules" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "The final list of non-conflicting rules."
          }
        },
        "required" => ["rules"]
      }
    }
  end

  def execute(args, _context) do
    {:ok, "Mediation complete: #{length(args["rules"] || [])} rules resolved."}
  end
end



