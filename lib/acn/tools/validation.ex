defmodule ACN.Tools.Validation do
  @moduledoc """
  Tools for the Validator Agent.
  """

  defmodule Static do
    @behaviour ACN.Tools.ToolBehaviour
    require Logger

    def definition do
      %{
        "name" => "report_static_status",
        "description" => "Report the result of a static code analysis.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "status" => %{
              "type" => "string",
              "enum" => ["CLEAN", "DIRTY"],
              "description" => "The verdict of the audit."
            },
            "issues" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of issues found (if DIRTY)."
            }
          },
          "required" => ["status", "issues"]
        }
      }
    end

    def execute(args) do
      status = args["status"]
      issues = args["issues"] || []
      
      Logger.info("Tool Validation.Static: Verdict #{status}")
      
      # We cast to the calling process (The Validator) to update its state
      GenServer.cast(self(), {:static_verdict, status, issues})
      
      "Verdict Recorded: #{status}"
    end
  end
end
