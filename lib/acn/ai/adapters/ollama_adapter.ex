defmodule ACN.AI.Adapters.OllamaAdapter do
  @moduledoc """
  Bridges ACN to an external Ollama instance hosting Tiny-Agent.
  Reuses the "Broca's Area" transpiler logic to speak Python to the model.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger
  alias ACN.AI.ModelBehavior.Response

  # CHANGE 1: Set timeout to 300s (Evidence: Generation takes ~142s on local hardware)
  @default_opts [receive_timeout: 300_000]

  @impl true
  def chat(messages, tools, opts \\ []) do
    config = config()
    req_opts = Keyword.merge(@default_opts, opts)

    # 1. Inbound Translation (Prepare Messages)
    # Unlike Nx.Serving which takes a raw string, Ollama takes a list of messages.
    # But we still need to inject the Python tool definitions into the system prompt.
    prepared_messages = prepare_messages_for_ollama(messages, tools)

    payload = %{
      model: req_opts[:model] || config[:model],
      messages: prepared_messages,
      stream: false, # Stable non-streaming mode
      options: %{
        temperature: req_opts[:temperature] || 0.1, # Low temp for code
        num_ctx: 4096, # Ensure high context
        # CHANGE 2: Force the model to stop if it tries to generate a User reply or end tag
        stop: ["<|im_end|>", "<|im_start|>", "User:", "Observation:"]
      }
    }

    # --- DEBUG VISIBILITY START ---
    IO.puts("\n\n🟢 [Ollama Input] ================================================")
    IO.puts("Model: #{payload.model}")
    
    # Check if Transpiler injected tools into System Prompt (First message)
    system_msg = List.first(prepared_messages)
    if String.contains?(system_msg[:content], "@tool") do
      IO.puts("✅ TRANSPILER ACTIVE: Python Tool Definitions detected in System Prompt.")
    else
      IO.puts("⚠️ TRANSPILER INACTIVE: No tools found in System Prompt.")
    end

    IO.puts("--- Full Context Sent ---")
    Enum.each(prepared_messages, fn msg -> 
      IO.puts("[#{String.upcase(msg.role)}]: #{msg.content}") 
    end)
    IO.puts("==================================================================\n")
    # --- DEBUG VISIBILITY END ---

    Logger.info("[Ollama] Reaching out to #{config[:base_url]} (Timeout: #{req_opts[:receive_timeout]}ms)...")

    case Req.post("#{config[:base_url]}/api/chat", 
      json: payload, 
      receive_timeout: req_opts[:receive_timeout],
      finch: ACN.HTTPClient) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.info("[Ollama] successfully reached and response received.")
        content = body["message"]["content"]
        
        # --- DEBUG VISIBILITY START ---
        IO.puts("\n\n🟣 [Ollama Output] ===============================================")
        IO.puts(content)
        IO.puts("==================================================================\n")
        # --- DEBUG VISIBILITY END ---

        case parse_python_to_tool_calls(content) do
          {:tool_calls, tool_calls} ->
            {:ok, %Response{
              content: content,
              tool_calls: tool_calls,
              finish_reason: "tool_calls",
              token_usage: %{total: 0}
            }}

          {:text, text} ->
            {:ok, %Response{
              content: text,
              tool_calls: nil,
              finish_reason: "stop",
              token_usage: %{total: 0}
            }}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Ollama] API Error: #{status}")
        {:error, {:ollama_error, status, body}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        Logger.error("[Ollama] TIMEOUT: Model took too long to generate. It may be hallucinating.")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("[Ollama] Network Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def embed(_text, _opts), do: {:error, :not_implemented}

  # --- Configuration ---
  defp config do
    Application.get_env(:acn, :ai, [])[:ollama] || 
      [base_url: "http://localhost:11434", model: "qwen3:0.6b"]
  end

  # --- Inbound Translation ---

  defp prepare_messages_for_ollama(messages, tools) do
    # 1. Build the Python Tool Definitions String
    python_tools = build_pythonic_tools(tools)

    # 2. Inject into System Prompt
    # We find the system message, append logic, or create one.
    {systems, others} = Enum.split_with(messages, &(&1[:role] == "system" or &1["role"] == "system"))
    
    system_content = 
      case systems do
        [] -> "You are a helpful AI assistant."
        msgs -> Enum.map_join(msgs, "\n", &(&1[:content] || &1["content"]))
      end

    full_system = system_content <> "\n\n" <> python_tools
    Logger.debug("[OllamaAdapter] Injected System Prompt (Start): #{String.slice(full_system, 0, 200)}...")
    Logger.debug("[OllamaAdapter] Injected Tools: #{Enum.map_join(tools, ", ", &(&1["name"] || &1[:name]))}")

    # 3. Map "tool" roles to "user" (Ollama might support tool roles but we simulate Python env)
    mapped_others = Enum.map(others, &map_role_and_content/1)

    [%{role: "system", content: full_system} | mapped_others]
  end

  defp map_role_and_content(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"]

    case role do
      "tool" ->
        # Map tool outputs to user messages so the model sees them as feedback
        %{role: "user", content: "Tool Output: #{content}"}

      "assistant" ->
        calls = msg[:tool_calls] || msg["tool_calls"]

        if is_list(calls) do
          new_calls =
            Enum.map(calls, fn call ->
              case call["function"]["arguments"] do
                bin when is_binary(bin) ->
                  # Decode string back to map for Ollama API
                  new_args =
                    case Jason.decode(bin) do
                      {:ok, map} -> map
                      _ -> bin
                    end

                  put_in(call, ["function", "arguments"], new_args)

                _ ->
                  call
              end
            end)

          %{role: "assistant", content: content, tool_calls: new_calls}
        else
          %{role: "assistant", content: content}
        end

      _ ->
        %{role: role, content: content}
    end
  end

  defp build_pythonic_tools([]), do: ""
  defp build_pythonic_tools(tools) do
    tools_str =
      tools
      |> Enum.map_join("\n\n", fn tool ->
        name = tool["name"] || tool[:name]
        desc = tool["description"] || tool[:description]
        params = tool["parameters"] || tool[:parameters] || %{}
        # Handle cases where parameter structure varies slightly
        props = params["properties"] || params[:properties] || %{}
        args = Map.keys(props) |> Enum.join(", ")

        "@tool\ndef #{name}(#{args}):\n    '''#{desc}'''\n    pass"
      end)
    
    """
    You have access to the following Python tools. 
    
    #{tools_str}
    
    To use a tool, you must output a valid Python function call within a code block.
    Example:
    ```python
    tool_name(arg1="value", arg2="value")
    ```
    DO NOT define functions. ONLY call them.
    """
  end

  # --- Outbound Translation (The Python Parser - COPIED from TinyAgentAdapter) ---

  defp parse_python_to_tool_calls(text) do
    # 1. Extract ALL Python Blocks
    blocks = Regex.scan(~r/```(?:python)?\s*(.*?)\s*```/s, text)
    
    if blocks == [] do
      # Fallback: Check if the whole text looks like it might contain a tool call (for lazy models)
      if String.contains?(text, "(") and String.contains?(text, ")") do
         parse_code(text)
      else
         {:text, text}
      end
    else
      # Combine all Python blocks
      combined_code = Enum.map_join(blocks, "\n", fn [_, code] -> code end)
      parse_code(combined_code)
    end
  end

  defp parse_code(code) do
    # Split multi-line function calls into individual complete calls
    # then parse each one
    complete_calls = extract_complete_calls(code)
    
    tool_calls = 
      complete_calls
      |> Enum.map(&parse_single_call/1)
      |> Enum.filter(&(&1 != nil))
    
    if tool_calls == [] do
      Logger.debug("[OllamaAdapter] No tool calls extracted from code block.")
      {:text, code}
    else
      Logger.info("[OllamaAdapter] Extracted #{length(tool_calls)} tool calls.")
      {:tool_calls, tool_calls}
    end
  end

  # Extract complete function calls (handles multi-line)
  defp extract_complete_calls(code) do
    lines = String.split(code, "\n")
    
    # Accumulate complete function calls
    {calls, _} = 
      Enum.reduce(lines, {[], nil}, fn line, {calls, current} ->
        trimmed = String.trim(line)
        
        cond do
          # Skip empty lines and comments
          trimmed == "" || String.starts_with?(trimmed, "#") || String.starts_with?(trimmed, "def") ->
            {calls, current}
          
          # Start of new function call
          String.match?(trimmed, ~r/^(?:\w+\s*=\s*)?\w+\(/) && current == nil ->
            # Check if it's a complete one-liner
            if String.contains?(trimmed, ")") do
              {[trimmed | calls], nil}
            else
              # Start of multi-line call
              {calls, trimmed}
            end
          
          # Continuation of multi-line call
          current != nil ->
            new_current = current <> " " <> trimmed
            # Check if this line closes the call
            if String.contains?(trimmed, ")") do
              {[new_current | calls], nil}
            else
              {calls, new_current}
            end
          
          true ->
            {calls, current}
        end
      end)
    
    Enum.reverse(calls)
  end

  # Parse a single complete function call (may be from multiple lines)
  defp parse_single_call(call_str) do
    # Extract function name and arguments from complete call string
    case Regex.run(~r/^(?:\w+\s*=\s*)?(\w+)\((.*)\)/, String.trim(call_str)) do
      [_, name, args_str] ->
        # Try named args first, fallback to positional if valid
        arguments = 
          case parse_args_string(args_str) do
            args when map_size(args) > 0 -> args
            _ -> parse_positional_args(name, args_str)
          end
        
        %{
          "id" => UUID.uuid4(),
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => Jason.encode!(arguments) 
          }
        }
      _ -> nil
    end
  end

  defp parse_args_string(str) do
    # Regex supports: triple-double, triple-single, double, single quotes, and basic lists.
    # Group 1: Key
    # Group 2: Triple-Double Value
    # Group 3: Triple-Single Value
    # Group 4: Double Value
    # Group 5: Single Value
    # Group 6: List Value [...]
    
    # IMPROVEMENT: Use non-greedy match for lists if followed by a comma and another key-value pair, 
    # or just be careful with the greedy dot.
    Regex.scan(~r/(\w+)\s*=\s*(?:"""(.*?)"""|'''(.*?)'''|"([^"]*)"|'([^']*)'|(\[.*?\]))(?:\s*,|$)/s, str)
    |> Map.new(fn match ->
        case match do
          [_, key, val, "", "", "", ""] -> {key, val} # Triple Double
          [_, key, "", val, "", "", ""] -> {key, val} # Triple Single
          [_, key, "", "", val, "", ""] -> {key, val} # Double
          [_, key, "", "", "", val, ""] -> {key, val} # Single
          [_, key, "", "", "", "", list_str] -> 
             # Robust list parsing: extract elements between quotes
             # Handles escaped quotes and ignores internal mismatched quotes by looking for delimiters
             elements = 
               Regex.scan(~r/(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)')\s*(?:,|$|\])/, list_str)
               |> Enum.map(fn 
                 [_, "", v] -> v # Single quote match
                 [_, v, ""] -> v # Double quote match
                 [_, v] -> v     # Single capture case (if only one kind of quote present)
                 _ -> nil
               end)
               |> Enum.reject(&is_nil/1)
             
             # Filter out empty or merely whitespace strings
             clean_elements = Enum.filter(elements, fn v -> String.trim(v) != "" end)
             
             {key, clean_elements}
          # Fallback
          [_, key | captures] -> 
             value = Enum.find(captures, &(&1 != "")) || ""
             {key, value}
        end
    end)
  end


  defp parse_positional_args("worksheet_write", args_str) do
    # Support: "file", "content" | 'file', 'content' | var1, var2 | "file", var2
    # This is a bit looser to handle model's unquoted variables as strings
    case Regex.run(~r/['"]?(.*?)['"]?\s*,\s*['"]?(.*?)['"]?/s, String.trim(args_str)) do
      [_, filename, content] -> 
        %{"filename" => String.trim(filename), "content" => String.trim(content)}
      _ -> %{}
    end
  end

  defp parse_positional_args("submit_legislation", args_str) do
    # Robust element extraction handles nested quotes and escapes
    elements = 
      Regex.scan(~r/(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)')\s*(?:,|$|\])/, args_str)
      |> Enum.map(fn 
        [_, "", v] -> v # Single quote match
        [_, v, ""] -> v # Double quote match
        [_, v] -> v     # Single capture case
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %{"rules" => elements}
  end

  defp parse_positional_args("submit_mediation", args_str) do
    parse_positional_args("submit_legislation", args_str)
  end

  defp parse_positional_args("submit_execution_plan", args_str) do
    # Try to parse as list of lists
    json_friendly = String.replace(args_str, "'", "\"")
    case Jason.decode(json_friendly) do
      {:ok, batches} when is_list(batches) -> %{"batches" => batches}
      _ -> %{}
    end
  end

  defp parse_positional_args("link_dependency", args_str) do
    # Matches: "A", "B" or 'A', 'B'
    case Regex.run(~r/['"](.*?)['"]\s*,\s*['"](.*?)['"]/s, args_str) do
      [_, p, c] -> %{"provider_task_id" => p, "consumer_task_id" => c}
      _ -> %{}
    end
  end

  defp parse_positional_args("set_node_identity", args_str) do
    # Matches: "LEAF" or "INTERMEDIATE" or 'LEAF' etc.
    case Regex.run(~r/['"](.*?)['"]/, args_str) do
      [_, identity] -> %{"identity" => identity}
      _ -> %{}
    end
  end

  defp parse_positional_args("query_wisdom", args_str) do
    # Matches first argument as query_text: "Query" or 'Query'
    case Regex.run(~r/['"](.*?)['"]/, args_str) do
      [_, query] -> %{"query_text" => query}
      _ -> %{}
    end
  end

  defp parse_positional_args(_, _), do: %{}
end
