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
      model: config[:model],
      messages: prepared_messages,
      stream: false,
      options: %{
        temperature: req_opts[:temperature] || 0.1, # Low temp for code
        num_ctx: 4096, # Ensure high context
        # CHANGE 2: Force the model to stop if it tries to generate a User reply or end tag
        stop: ["<|im_end|>", "<|im_start|>", "User:", "Observation:"]
      }
    }

    # --- DEBUG VISIBILITY START ---
    IO.puts("\n\n🟢 [Ollama Input] ================================================")
    IO.puts("Model: #{config[:model]}")
    
    # Check if Transpiler injected tools into System Prompt (First message)
    system_msg = List.first(prepared_messages)
    if String.contains?(system_msg[:content], "@tool") do
      IO.puts("✅ TRANSPILER ACTIVE: Python Tool Definitions detected in System Prompt.")
    else
      IO.puts("⚠️ TRANSPILER INACTIVE: No tools found in System Prompt.")
    end

    IO.puts("--- Full Context Sent ---")
    Enum.each(prepared_messages, fn msg -> 
      IO.puts("[#{String.upcase(msg.role)}]: #{String.slice(msg.content, 0, 500)}...") 
    end)
    IO.puts("==================================================================\n")
    # --- DEBUG VISIBILITY END ---

    Logger.debug("[Ollama] Sending Tool Request... (Timeout: #{req_opts[:receive_timeout]}ms)")

    # CHANGE 3: Add explicit error handling for timeouts
    case Req.post("#{config[:base_url]}/api/chat", json: payload, receive_timeout: req_opts[:receive_timeout]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
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
      [base_url: "http://localhost:11434", model: "tiny-agent"]
  end

  # --- Inbound Translation ---

  defp prepare_messages_for_ollama(messages, tools) do
    # 1. Build the Python Tool Definitions String
    python_tools = build_pythonic_tools(tools)

    # 2. Inject into System Prompt
    # We find the system message, append logic, or create one.
    {systems, others} = Enum.split_with(messages, &(&1.role == "system"))
    
    system_content = 
      case systems do
        [] -> "You are a helpful AI assistant."
        msgs -> Enum.map_join(msgs, "\n", & &1.content)
      end

    full_system = system_content <> "\n\n" <> python_tools

    # 3. Map "tool" roles to "user" (Ollama might support tool roles but we simulate Python env)
    mapped_others = Enum.map(others, &map_role_and_content/1)

    [%{role: "system", content: full_system} | mapped_others]
  end

  defp map_role_and_content(%{role: "tool", content: content}) do
    # Map tool outputs to user messages so the model sees them as feedback
    %{role: "user", content: "Tool Output: #{content}"}
  end

  defp map_role_and_content(%{role: "assistant", tool_calls: calls} = msg) when is_list(calls) do
    new_calls = Enum.map(calls, fn call ->
       case call["function"]["arguments"] do
         bin when is_binary(bin) -> 
            # Decode string back to map for Ollama API
            new_args = 
              case Jason.decode(bin) do
                {:ok, map} -> map
                _ -> bin 
              end
            put_in(call, ["function", "arguments"], new_args)
         _ -> call
       end
    end)
    %{msg | tool_calls: new_calls}
  end

  defp map_role_and_content(msg), do: msg

  defp build_pythonic_tools([]), do: ""
  defp build_pythonic_tools(tools) do
    tools_str = 
      tools
      |> Enum.map_join("\n\n", fn tool ->
        name = tool["name"]
        desc = tool["description"]
        # Handle cases where parameter structure varies slightly
        props = tool["parameters"]["properties"] || %{}
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
    # 1. Extract Python Block
    case Regex.run(~r/```python\s*(.*?)\s*```/s, text) do
      [_, code] -> parse_code(code)
      nil -> {:text, text}
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
      {:text, code}
    else
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
    # Regex supports: triple-double, triple-single, double, and single quotes.
    # Group 1: Key
    # Group 2: Triple-Double Value
    # Group 3: Triple-Single Value
    # Group 4: Double Value
    # Group 5: Single Value
    
    Regex.scan(~r/(\w+)\s*=\s*(?:"""(.*?)"""|'''(.*?)'''|"([^"]*)"|'([^']*)')/s, str)
    |> Map.new(fn match ->
        case match do
          [_, key, val, "", "", ""] -> {key, val} # Triple Double
          [_, key, "", val, "", ""] -> {key, val} # Triple Single
          [_, key, "", "", val, ""] -> {key, val} # Double
          [_, key, "", "", "", val] -> {key, val} # Single
          # Fallback for weird captures or if regex engine behavior differs slighty on groups
          [_, key | captures] -> 
             value = Enum.find(captures, &(&1 != "")) || ""
             {key, value}
        end
    end)
  end


  defp parse_positional_args("worksheet_write", args_str) do
    # Simple regex for 2 quoted string arguments
    # Matches: 'val1', 'val2' or "val1", "val2"
    case Regex.run(~r/['"](.*?)['"]\s*,\s*['"](.*?)['"]/s, args_str) do
      [_, filename, content] -> 
        %{"filename" => filename, "content" => content}
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

  defp parse_positional_args(_, _), do: %{}
end
