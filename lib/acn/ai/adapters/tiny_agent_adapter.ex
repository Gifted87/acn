defmodule ACN.AI.Adapters.TinyAgentAdapter do
  @moduledoc """
  The Broca’s Area: Translates between ACN's JSON vernacular and Tiny-Agent's Pythonic dialect.
  Handling the impedance mismatch between structured JSON tool calls and Python function signatures.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger

  alias ACN.AI.ModelBehavior.Response

  @serving_name ACN.LocalLLM

  @impl true
  def chat(messages, tools, _opts \\ []) do
    # 1. Inbound Translation
    prompt = build_prompt(messages, tools)

    # 2. Inference call to the Hippocampus
    # batched_run blocks until the result is ready. 
    # Serving is configured with batch_size: 1, so this is effectively synchronous for us.
    result = Nx.Serving.batched_run(@serving_name, prompt)
    
    # Nx.Serving returns %{results: [%{text: "..."}]} for Text.generation
    generated_text = result.results |> hd() |> Map.get(:text)

    # 3. Outbound Translation
    case parse_python_to_tool_calls(generated_text) do
      {:tool_calls, tool_calls} ->
        {:ok, %Response{
          content: nil,
          tool_calls: tool_calls,
          finish_reason: "tool_calls",
          token_usage: %{total: 0, completion: 0, prompt: 0} 
        }}
      
      {:text, content} ->
        {:ok, %Response{
          content: content,
          tool_calls: nil,
          finish_reason: "stop",
          token_usage: %{total: 0, completion: 0, prompt: 0}
        }}
    end
  end

  @impl true
  def embed(_text, _opts), do: {:error, :not_implemented}

  # --- Inbound Translation (The Pythonic Prompt) ---

  defp build_prompt(messages, tools) do
    # Inject tool definitions into system prompt
    python_tools = build_pythonic_tools(tools)
    
    messages
    |> Enum.map(&map_role_and_content/1)
    |> inject_system_instruction(python_tools)
    |> Enum.map_join("\n", &format_chatml/1)
    |> Kernel.<>("\n<|im_start|>assistant\n") # Trigger generation
  end
  
  defp map_role_and_content(%{role: "tool", content: content}) do
    # Map tool outputs to user messages so the model sees them as feedback
    %{role: "user", content: "Tool Output: #{content}"}
  end
  defp map_role_and_content(msg), do: msg

  defp inject_system_instruction(messages, python_tools) do
    {systems, others} = Enum.split_with(messages, &(&1.role == "system"))
    
    system_content = 
      case systems do
        [] -> "You are a helpful AI assistant."
        msgs -> Enum.map_join(msgs, "\n", & &1.content)
      end

    full_system = system_content <> "\n\n" <> python_tools
    
    # Reconstruct with single system message at head
    [%{role: "system", content: full_system} | others]
  end

  defp build_pythonic_tools([]), do: ""
  defp build_pythonic_tools(tools) do
    tools_str = 
      tools
      |> Enum.map_join("\n\n", fn tool ->
        name = tool["name"]
        desc = tool["description"]
        args = 
          tool["parameters"]["properties"] 
          |> Map.keys() 
          |> Enum.join(", ")
        
        "@tool\ndef #{name}(#{args}):\n    '''#{desc}'''\n    pass"
      end)
    
    """
    You have access to the following Python tools. To use them, output valid Python code inside a markdown block.
    
    #{tools_str}
    """
  end

  defp format_chatml(%{role: role, content: content}) do
    "<|im_start|>#{role}\n#{content}\n<|im_end|>"
  end

  # --- Outbound Translation (The Python Parser) ---

  defp parse_python_to_tool_calls(text) do
    # 1. Extract Python Block
    # Look for ```python ... ```
    case Regex.run(~r/```python\s*(.*?)\s*```/s, text) do
      [_, code] -> parse_code(code)
      nil -> {:text, text} # No code block, return raw text
    end
  end

  defp parse_code(code) do
    # Heuristic parsing: Identify `function_name(args)`
    # Ignore lines starting with `def` or `#`
    
    lines = String.split(code, "\n")
    call_line_idx = Enum.find_index(lines, fn line -> 
      line = String.trim(line)
      line != "" and not String.starts_with?(line, "def") and not String.starts_with?(line, "#") and String.match?(line, ~r/^\w+\(/)
    end)

    if call_line_idx do
       # Re-join from the call line onwards to handle multi-line args
       relevant_code = Enum.slice(lines, call_line_idx..-1) |> Enum.join("\n")
       
       # Extract name and args content
       case Regex.run(~r/^(\w+)\((.*)\)/s, String.trim(relevant_code)) do
         [_, name, args_str] ->
           arguments = parse_args_string(args_str)
           
           tool_call = %{
             "id" => UUID.uuid4(),
             "type" => "function",
             "function" => %{
               "name" => name,
               "arguments" => Jason.encode!(arguments) 
             }
           }
           {:tool_calls, [tool_call]}
           
         _ -> {:text, code} # Regex failed to parse call structure
       end
    else
       {:text, code} # No function call found
    end
  end

  defp parse_args_string(str) do
    # Robust argument parsing for `key="value"` or `key="""value"""`
    # Handles whitespace around equals.
    
    # Regex explanation:
    # (\w+)          -> Capture key
    # \s*=\s*        -> Equals with optional whitespace
    # (?:            -> Non-capturing group for values
    #   """(.*?)"""  -> Triple quoted string (Group 2)
    #   |            -> OR
    #   "([^"]*)"    -> Double quoted string (Group 3)
    # )
    
    Regex.scan(~r/(\w+)\s*=\s*(?:"""(.*?)"""|"([^"]*)")/s, str)
    |> Map.new(fn match ->
        case match do
          [_, key, val_triple, ""] -> {key, val_triple}
          [_, key, "", val_single] -> {key, val_single}
          [_, key, val_triple, _] -> {key, val_triple || ""} # Fallback
          _ -> {Enum.at(match, 1), ""} # Should not happen if regex matches
        end
    end)
  end
end
