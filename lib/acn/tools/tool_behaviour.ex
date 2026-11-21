defmodule ACN.Tools.ToolBehaviour do
  @moduledoc """
  Defines the contract for all Agent Tools.
  Every tool exposed to the LLM must implement this behaviour.
  """

  @doc """
  Returns the JSON Schema definition for the tool.
  Format must be compatible with OpenAI function calling.
  Example:
  %{
    "name" => "fs_write",
    "description" => "Writes text to a file",
    "parameters" => %{
      "type" => "object",
      "properties" => %{...},
      "required" => ["path", "content"]
    }
  }
  """
  @callback definition() :: map()

  @doc """
  Executes the tool with the given arguments.
  
  Args:
  - args: Map of arguments (parsed from JSON).
  
  Returns:
  - {:ok, result} : Successful execution output (text or multimodal content for the LLM).
  - {:error, reason_string} : Failure message (to be fed back to LLM).
  """
  @callback execute(args :: map(), env :: map()) :: {:ok, any()} | {:ok, any(), map()} | {:error, String.t()}
end
