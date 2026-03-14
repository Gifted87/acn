defmodule ACN.Tools.Governance.SubmitBlueprint do
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      name: "submit_blueprint",
      description: "Submits a finalised technical blueprint (Pillar I) containing architectural specifications and an explicit output contract.",
      parameters: %{
        type: "object",
        properties: %{
          target_path: %{
            type: "string",
            description: "The absolute path where the work will be performed."
          },
          init_command: %{
            type: "string",
            description: "Optional shell command to initialize the directory structure (e.g., mkdir -p)."
          },
          technical_specifications: %{
            type: "string",
            description: "Detailed technical specifications and instructions for the drafter."
          },
          file_manifest: %{
            type: "array",
            items: %{type: "string"},
            description: "REQUIRED: The explicit list of relative file paths this node and its children will produce (e.g. ['server.js', 'routes/tasks.js', 'models/task.js']). This is the output contract. Every file listed MUST be created."
          }
        },
        required: ["target_path", "technical_specifications", "file_manifest"]
      }
    }
  end

  @impl true
  def execute(_args, _context) do
    # This tool is primarily a structured output shim for the Controller to consume.
    # The Controller intercepts the tool call message directly.
    {:ok, "Blueprint Submitted"}
  end
end
