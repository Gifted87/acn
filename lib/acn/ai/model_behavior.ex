defmodule ACN.AI.ModelBehavior do
  @moduledoc """
  Defines the contract for an Intelligence Provider (LLM Adapter).
  Any module implementing this behavior can plug into the Cognitive Loop.
  """

  defmodule Response do
    @type t :: %__MODULE__{
      content: String.t() | list(map()) | nil,
      thinking: String.t() | nil,
      tool_calls: list(map()) | nil,
      token_usage: map() | nil,
      finish_reason: String.t() | nil
    }
    defstruct [:content, :thinking, :tool_calls, :token_usage, :finish_reason]
  end

  @type message :: %{
    role: String.t(), # "user" | "system" | "assistant" | "tool"
    content: String.t() | list(map()) | nil,
    tool_calls: list(map()) | nil, # Optional, for assistant messages
    tool_call_id: String.t() | nil # Optional, for tool messages
  }

  @type tool_definition :: map() # JSON Schema map
  @type options :: keyword()

  @doc """
  Generates a chat completion.
  
  Args:
  - messages: List of standardized message maps.
  - tools: List of JSON Schema definitions for available tools.
  - opts: Configuration overrides (e.g., timeout, temperature).
  
  Returns:
  - {:ok, Response.t()} on success.
  - {:error, reason} on failure (after retries).
  """
  @callback chat(messages :: list(message()), tools :: list(tool_definition()), opts :: options()) ::
              {:ok, Response.t()} | {:error, any()}

  @doc """
  Generates cognitive embeddings for a given text.
  
  Args:
  - text: The input string.
  - opts: Configuration overrides.
  
  Returns:
  - {:ok, list(float())} on success.
  - {:error, any()} on failure.
  """
  @callback embed(text :: String.t(), opts :: options()) ::
              {:ok, list(float())} | {:error, any()}
end
