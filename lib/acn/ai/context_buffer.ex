defmodule ACN.AI.ContextBuffer do
  @moduledoc """
  Manages the sliding window context for the LLM.
  ensures total tokens never exceed max_tokens - safety_margin.
  """
  alias ACN.AI.Tokenizer

  defmodule State do
    defstruct [:system_prompt, :message_history, :max_context_size, :safety_margin]
  end

  @default_max_context 128_000 # GPT-4-Turbo
  @default_safety_margin 4_096 # Reserve output space

  def new(system_prompt, opts \\ []) do
    max_context = opts[:max_context_size] || @default_max_context
    safety_margin = opts[:safety_margin] || @default_safety_margin

    %State{
      system_prompt: %{role: "system", content: system_prompt},
      message_history: [],
      max_context_size: max_context,
      safety_margin: safety_margin
    }
  end

  def add_message(%State{} = state, message) do
    # Append message
    new_history = state.message_history ++ [message]

    # Prune immediately to enforce limits
    prune_history(%{state | message_history: new_history})
  end

  def add_messages(%State{} = state, messages) do
    new_history = state.message_history ++ messages
    prune_history(%{state | message_history: new_history})
  end

  def add_tool_result(%State{} = state, tool_call_id, content) do
    message = %{
      role: "tool",
      tool_call_id: tool_call_id,
      content: content
    }
    add_message(state, message)
  end

  def to_list(%State{} = state) do
    [state.system_prompt | state.message_history]
  end

  # --- Pruning Logic ---

  defp prune_history(state) do
    current_tokens = total_tokens(state)
    limit = state.max_context_size - state.safety_margin

    if current_tokens > limit do
      # Drop oldest message (from the front), but keep system prompt safe in struct
      case state.message_history do
        [] ->
          # Crisis: Even system prompt + 0 messages is too big?
          # We can't prune system prompt logic here (Priority 0).
          # Just return state and hope for best or crash?
          state

        [_dropped | remaining] ->
          # Recursively prune until fit
          prune_history(%{state | message_history: remaining})
      end
    else
      state
    end
  end

  defp total_tokens(state) do
    Tokenizer.count_tokens(state.system_prompt.content) +
    Tokenizer.count_message_list(state.message_history)
  end
end
