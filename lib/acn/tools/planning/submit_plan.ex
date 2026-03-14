defmodule ACN.Tools.Planning.SubmitPlan do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      "name" => "submit_plan",
      "description" => "Submit the batched execution plan.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "batches" => %{
            "type" => "array",
            "description" => "List of batches, where each batch is a list of task objects.",
            "items" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "description" => %{"type" => "string"},
                    "output_slot" => %{"type" => "string"},
                    "path" => %{"type" => "string", "description" => "Absolute path where the task is performed"}
                  },
                  "required" => ["id", "description", "output_slot", "path"]
              }
            }
          }
        },
        "required" => ["batches"]
      }
    }
  end

  def execute(args, _env) do
    # Just return the data, the Agent handles it.
    args["batches"]
  end
end
