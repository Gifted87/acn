defmodule ACN.AI.Pipeline do
  @moduledoc """
  The Cognitive Loop (ReAct Engine).
  Orchestrates the flow: Prompt -> LLM -> Tool -> Execution -> Result -> LLM.
  """
  require Logger
  alias ACN.AI.{ContextBuffer, ModelBehavior}
  alias ACN.Tools.Registry



  @doc """
  Runs the cognitive loop.

  Args:
  - buffer: ACN.AI.ContextBuffer struct
  - tools: List of tool names (strings) available to the agent
  - config: Map containing :adapter_module and :adapter_opts

  Returns:
  - {:ok, final_message, updated_buffer, updated_env}
  - {:error, reason}
  """
  def run(buffer, tool_names, config, env \\ %{}) do
    # 1. Resolve Tool Definitions
    tool_modules = Registry.lookup_all(tool_names)
    tool_definitions = Enum.map(tool_modules, & &1.definition())
 
    # 2. Start Execution
    attempts = config[:max_attempts] || 3
    do_run(buffer, tool_modules, tool_definitions, config, env, attempts)
  end


  defp do_run(buffer, tool_modules, tool_definitions, config, env, attempts) when attempts > 0 do
    adapter = config[:adapter] || ACN.AI.Adapters.OllamaAdapter
    opts = config[:opts] || []

    # 3. Call AI
    messages = ContextBuffer.to_list(buffer)

    case adapter.chat(messages, tool_definitions, opts) do
      {:ok, response} ->
        # AUDIT: Log the interaction
        # We need node_id, assuming it's in config or env?
        # For now, let's use a placeholder or extract from env if available
        node_id = env[:node_id] || "unknown_node"
        bot_name = config[:bot_name] || "unknown_bot"
        
        ACN.Observability.AuditLogger.log_bot_io(
          node_id, 
          bot_name, 
          "AI_EXECUTION", 
          messages, 
          response.content || "TOOL_CALL"
        )

        # Tool Call Enforcement: Rerun if tool_choice is ANY but no tool was called
        tool_choice = opts[:tool_choice] || config[:tool_choice] || profile_tool_choice(config)
        force_tool = config[:force_tool] || (tool_choice == "ANY")
        has_tool_calls = response.tool_calls != nil && length(response.tool_calls) > 0

        if force_tool && !has_tool_calls do
          Logger.warning("[Pipeline] Tool call REQUIRED but missing. Retrying (Attempts left: #{attempts - 1})...")
          
          # Inject nudge to force tool use
          nudge = %{role: "user", content: "CRITICAL: You MUST call one of the available tools. Do not just provide a text response."}
          new_buffer = ContextBuffer.add_message(buffer, nudge)
          
          do_run(new_buffer, tool_modules, tool_definitions, config, env, attempts - 1)
        else
          handle_response(response, buffer, tool_modules, tool_definitions, config, env)
        end
 
      {:error, reason} ->
        Logger.warning("[Pipeline] AI Error: #{inspect(reason)}. Retrying (Attempts left: #{attempts - 1})...")
        do_run(buffer, tool_modules, tool_definitions, config, env, attempts - 1)
    end
  end

  defp do_run(_buffer, _tool_modules, _tool_definitions, _config, _env, 0) do
    Logger.error("[Pipeline] Max attempts reached. Failing.")
    {:error, :max_attempts_reached}
  end

  defp profile_tool_choice(config) do
    # Helpers to extract from nested profile structures if available
    if config[:profile] && is_map(config[:profile]) do
       config[:profile]["tool_choice"]
    else
       nil
    end
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: nil} = response, buffer, _, _, _, env) do
    # 4a. Simple Text Response -> Done
    Logger.info("[Pipeline] AI returned simple text: #{String.slice(response.content || "", 0, 100)}...")
    final_msg = %{role: "assistant", content: response.content}
    new_buffer = ContextBuffer.add_message(buffer, final_msg)
    {:ok, final_msg, new_buffer, env}
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: []} = response, buffer, _, _, _, env) do
      # Empty list same as nil
      final_msg = %{role: "assistant", content: response.content}
      new_buffer = ContextBuffer.add_message(buffer, final_msg)
      {:ok, final_msg, new_buffer, env}
  end

  defp handle_response(%ModelBehavior.Response{tool_calls: tool_calls} = response, buffer, modules, _defs, _config, env) do
    # 4b. Tool Calls detected -> Execute and Recurse

    # First, append the Assistant's "Call" message to history
    assistant_msg = %{
      role: "assistant",
      content: response.content || "",
      tool_calls: tool_calls
    }
    buffer_with_call = ContextBuffer.add_message(buffer, assistant_msg)

    # Execute Tools (Sequential for now, could be parallel)
    {tool_results, updated_env} =
      Enum.reduce(tool_calls, {[], env}, fn call, {results, curr_env} ->
        {res, next_env} = execute_tool(call, modules, curr_env)
        {results ++ [res], next_env}
      end)

    # Append Tool Outputs to history
    buffer_with_results = ContextBuffer.add_messages(buffer_with_call, tool_results)

    # RE-ACT LOOP REMOVED as per architectural directive.
    # We return the actual assistant message that triggered the tools
    # so the caller can extract the results or proceed to the next stage.
    {:ok, assistant_msg, buffer_with_results, updated_env}
  end

  defp execute_tool(%{"function" => func, "id" => call_id}, modules, env) do
    tool_name = func["name"]
    args_json = func["arguments"]

    # Find module matching definition name
    # We have list of modules. We need to find the one where def.name == tool_name
    # Optimization: Create a map lookup in `run/3`?
    # For now, simplistic iteration over modules list (assuming small count)

    module = Enum.find(modules, fn mod ->
      mod.definition()["name"] == tool_name
    end)

    {output, updated_env} =
      if module do
        case Jason.decode(args_json) do
          {:ok, args} ->
            try do
              # Determine calling convention (args or args+env)
              case module.execute(args, env) do
                {:ok, result, next_env} -> {result, next_env}
                {:ok, result} when module == ACN.Tools.Lattice.UpstreamMerge ->
                  {result, Map.put(env, :upstream_merge_dbc, result)}
                {:ok, result} -> {result, env}
                {:error, reason} -> {"Error: #{reason}", env}
                other -> {other, env}
              end
            rescue
              e -> {"Error executing tool: #{inspect(e)}", env}
            end
          {:error, _} -> {"Error: Invalid JSON arguments", env}
        end
      else
        {"Error: Tool #{tool_name} not found in registry subset.", env}
      end
 
    # Format as Tool Message
    message = %{
      role: "tool",
      tool_call_id: call_id,
      content: normalize_tool_output(output)
    }
    {message, updated_env}
  end

  defp normalize_tool_output(output) when is_binary(output), do: output

  defp normalize_tool_output(output) when is_list(output) do
    if Enum.all?(output, fn
         %{"type" => type} when type in ["text", "image_url"] -> true
         %{type: type} when type in ["text", "image_url"] -> true
         _ -> false
       end) do
      output
    else
      encode_tool_output(output)
    end
  end

  defp normalize_tool_output(output), do: encode_tool_output(output)

  defp encode_tool_output(output) do
    case Jason.encode(output) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(output, limit: :infinity, printable_limit: :infinity)
    end
  end
end
