defmodule ACN.AI.Tokenizer do
  @moduledoc """
  Service for counting tokens in text and messages.
  Currently uses an advanced heuristic fallback (Character Count / 3.5).
  """

  @doc """
  Counts tokens in a string.
  Heuristic: 1 token ~= 3.5 - 4 chars. We use 3.5 to be safe (over-estimate slightly).
  """
  @spec count_tokens(any()) :: integer()
  def count_tokens(nil), do: 0
  def count_tokens(text) when not is_binary(text) do
    # Fallback for non-string types (e.g. lists, maps injected by accident)
    count_tokens(inspect(text))
  end
  def count_tokens(text) do
    case ACN.Actuator.RustlerBridge.count_tokens_nif(text) do
      {:ok, count} -> count
      {:error, reason} -> 
        require Logger
        Logger.error("Tokenizer NIF Failed: #{inspect(reason)}")
        (String.length(text) / 3.5) |> ceil()
      _ -> 0
    end
  end

  @doc """
  Counts tokens in a list of message maps.
  Accounts for message overhead (<|im_start|>, roles, etc).
  """
  @spec count_message_list(list(map())) :: integer()
  def count_message_list(messages) do
    # Overhead per message (format wrappers)
    # Approx 3 tokens per message for formatting
    per_message_overhead = 3
    
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = count_tokens(msg[:content])
      
      # Count tool calls if present (json payload)
      tool_tokens = 
        if msg[:tool_calls] do
          count_tokens(Jason.encode!(msg[:tool_calls])) 
        else
          0
        end

      acc + content_tokens + tool_tokens + per_message_overhead
    end)
  end
end
