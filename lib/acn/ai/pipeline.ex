defmodule ACN.AI.Pipeline do
  @moduledoc """
  The Cognitive Loop (ReAct Engine).
  Orchestrates the flow: Prompt -> LLM -> Tool -> Execution -> Result -> LLM.
  """
  require Logger
  alias ACN.AI.{ContextBuffer, ModelBehavior}
  alias ACN.Tools.Registry

  @max_turns 5

  @doc """
  Runs the cognitive loop.

  Args:
  - buffer: ACN.AI.ContextBuffer struct
  - tools: List of tool names (strings) available to the agent
  - config: Map containing :adapter_module and :adapter_opts

  Returns:
  - {:ok, final_message, updated_buffer}
  - {:error, reason}
  """
  def run(buffer, tool_names, config) do
    # 1. Resolve Tool Definitions
    tool_modules = Registry.lookup_all(tool_names)
    tool_definitions = Enum.map(tool_modules, & &1.definition())

    # 2. Start Loop
    do_run(buffer, tool_modules, tool_definitions, config, 0)
  end

  defp do_run(_buffer, _modules, _defs, _config, turns) when turns >= @max_turns do
    {:error, :max_turns_exceeded}
  end

  defp do_run(buffer, tool_modules, tool_definitions, config, turns) do
    adapter = config[:adapter] || ACN.AI.Adapters.OpenAI
    opts = config[:opts] || []

    # 2.5 Check Homeostasis (Throttle)
    ACN.Agents.LiveWire.wait_for_homeostasis()

    # 3. Call AI
    messages = ContextBuffer.to_list(buffer)

    case adapter.chat(messages, tool_definitions, opts) do
      {:ok, response} ->
        handle_response(response, buffer, tool_modules, tool_definitions, config, turns)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: nil} = response, buffer, _, _, _, _) do
    # 4a. Simple Text Response -> Done
    final_msg = %{role: "assistant", content: response.content}
    new_buffer = ContextBuffer.add_message(buffer, final_msg)
    {:ok, final_msg, new_buffer}
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: []} = response, buffer, _, _, _, _) do
      # Empty list same as nil
      final_msg = %{role: "assistant", content: response.content}
      new_buffer = ContextBuffer.add_message(buffer, final_msg)
      {:ok, final_msg, new_buffer}
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: tool_calls} = response, buffer, modules, defs, config, turns) do
    # 4b. Tool Calls detected -> Execute and Recurse

    # First, append the Assistant's "Call" message to history
    assistant_msg = %{
      role: "assistant",
      content: response.content || "",
      tool_calls: tool_calls
    }
    buffer_with_call = ContextBuffer.add_message(buffer, assistant_msg)

    # Execute Tools (Sequential for now, could be parallel)
    tool_results =
      Enum.map(tool_calls, fn call ->
        execute_tool(call, modules)
      end)

    # Append Tool Outputs to history
    buffer_with_results = ContextBuffer.add_messages(buffer_with_call, tool_results)

    # Recurse (The "Loop")
    do_run(buffer_with_results, modules, defs, config, turns + 1)
  end

  defp execute_tool(%{"function" => func, "id" => call_id}, modules) do
    tool_name = func["name"]
    args_json = func["arguments"]

    # Find module matching definition name
    # We have list of modules. We need to find the one where def.name == tool_name
    # Optimization: Create a map lookup in `run/3`?
    # For now, simplistic iteration over modules list (assuming small count)

    module = Enum.find(modules, fn mod ->
      mod.definition()["name"] == tool_name
    end)

    output =
      if module do
        case Jason.decode(args_json) do
          {:ok, args} ->
            case module.execute(args) do
              {:ok, result} -> result
              {:error, reason} -> "Error: #{reason}"
            end
          {:error, _} -> "Error: Invalid JSON arguments"
        end
      else
        "Error: Tool #{tool_name} not found in registry subset."
      end

    # Format as Tool Message
    %{
      role: "tool",
      tool_call_id: call_id,
      content: output
    }
  end
end
