defmodule ACN.AI.Adapters.OllamaAdapter do
  @moduledoc """
  Bridges ACN to an external Ollama instance hosting Tiny-Agent.
  Reuses the "Broca's Area" transpiler logic to speak Python to the model.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger
  alias ACN.AI.ModelBehavior.Response

  @default_opts [receive_timeout: 120_000]

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
        num_ctx: 4096 # Ensure high context
      }
    }

    # 2. Transport (HTTP to Ollama)
    case Req.post("#{config[:base_url]}/api/chat", json: payload, receive_timeout: req_opts[:receive_timeout]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Extract content
        content = body["message"]["content"]

        # 3. Outbound Translation (Parse Python)
        case parse_python_to_tool_calls(content) do
          {:tool_calls, tool_calls} ->
            {:ok, %Response{
              content: content,
              tool_calls: tool_calls,
              finish_reason: "tool_calls",
              token_usage: %{total: 0} # Ollama doesn't always return usage in simple chat
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
        Logger.error("Ollama API Error: #{status} - #{inspect(body)}")
        {:error, {:ollama_error, status, body}}

      {:error, reason} ->
        Logger.error("Ollama Network Error: #{inspect(reason)}")
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
    lines = String.split(code, "\n")
    call_line_idx = Enum.find_index(lines, fn line -> 
      line = String.trim(line)
      line != "" and not String.starts_with?(line, "def") and not String.starts_with?(line, "#") and String.match?(line, ~r/^\w+\(/)
    end)

    if call_line_idx do
       relevant_code = Enum.slice(lines, call_line_idx..-1) |> Enum.join("\n")
       case Regex.run(~r/^(\w+)\((.*)\)/s, String.trim(relevant_code)) do
         [_, name, args_str] ->
           # Try named args first, fallback to positional if valid
           arguments = 
             case parse_args_string(args_str) do
                args when map_size(args) > 0 -> args
                _ -> parse_positional_args(name, args_str)
             end
           
           tool_call = %{
             "id" => UUID.uuid4(),
             "type" => "function",
             "function" => %{
               "name" => name,
               "arguments" => Jason.encode!(arguments) 
             }
           }
           {:tool_calls, [tool_call]}
         _ -> {:text, code}
       end
    else
       {:text, code}
    end
  end

  defp parse_args_string(str) do
    Regex.scan(~r/(\w+)\s*=\s*(?:"""(.*?)"""|"([^"]*)")/s, str)
    |> Map.new(fn match ->
        case match do
          [_, key, val_triple, ""] -> {key, val_triple}
          [_, key, "", val_single] -> {key, val_single}
          [_, key, val_triple, _] -> {key, val_triple || ""}
          _ -> {Enum.at(match, 1), ""}
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
  defp parse_positional_args(_, _), do: %{}
end
