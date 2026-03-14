defmodule ACN.Tools.Strategy.SubmitStrategy do
  @behaviour ACN.Tools.ToolBehaviour
  require Logger

  @impl true
  def definition do
    %{
      "name" => "submit_strategy",
      "description" => "Submits a remediation strategy to guide the Actuator after a failure.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "diagnosis" => %{
            "type" => "string",
            "description" => "Technical root cause analysis of the failure."
          },
          "remediation_steps" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Sequence of corrective actions the Actuator must perform."
          },
          "specialist_hint" => %{
            "type" => "string",
            "description" => "A direct, low-level instruction for the specialist_drafter."
          }
        },
        "required" => ["diagnosis", "remediation_steps", "specialist_hint"]
      }
    }
  end

  @impl true
  def execute(args, _context) do
    Logger.info("Tool Strategy: Remediation plan submitted. Hint: #{args["specialist_hint"]}")
    {:ok, "Strategy submitted successfully."}
  end
end
