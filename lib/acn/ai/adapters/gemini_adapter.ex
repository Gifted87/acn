defmodule ACN.AI.Adapters.GeminiAdapter do
  @moduledoc """
  Adapter for Google Gemini API.
  Implements native function calling without Python transpilation.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger
  alias ACN.AI.ModelBehavior.Response

  # Match other adapters timeout for consistency
  @default_opts [receive_timeout: 300_000]

  @impl true
  def chat(messages, tools, opts \\ []) do
    config = config()
    req_opts = Keyword.merge(@default_opts, opts)

    # Validate API key
    api_key = config[:api_key] || System.get_env("GEMINI_API_KEY")
    
    if is_nil(api_key) or api_key == "" do
      Logger.error("[GeminiAdapter] Missing API key. Set GEMINI_API_KEY environment variable.")
      {:error, :missing_api_key}
    else
      do_chat(api_key, messages, tools, config, req_opts)
    end
  end

  defp do_chat(api_key, messages, tools, config, req_opts) do
    # Build request payload
    payload = build_request_payload(messages, tools, config, req_opts)
    
    # Debug logging
    log_request(payload, tools, config)

    # Make API call - PRIORITIZE RUNTIME OPTS
    model = req_opts[:model] || config[:model] || "gemini-3.1-flash-lite-preview"
    endpoint = "https://aiplatform.googleapis.com/v1/publishers/google/models/#{model}:generateContent?key=#{api_key}"
    
    headers = [
      {"content-type", "application/json"}
    ]

    Logger.info("[GeminiAdapter] Calling #{endpoint} (Timeout: #{req_opts[:receive_timeout]}ms)...")

    make_request_with_retry(endpoint, [json: payload, headers: headers, receive_timeout: req_opts[:receive_timeout], finch: ACN.HTTPClient], 0)
    |> parse_response()
  end

  defp make_request_with_retry(endpoint, req_params, retry_count) do
    case Req.post(endpoint, req_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.info("[GeminiAdapter] Successfully received response.")
        body

      {:ok, %Req.Response{status: status, body: body}} ->
        if retry_count < 3 do
          Logger.error("[GeminiAdapter] API Error (Status: #{status}). Retrying in 5000ms... (Attempt #{retry_count + 1})")
          Process.sleep(5000)
          make_request_with_retry(endpoint, req_params, retry_count + 1)
        else
          Logger.error("[GeminiAdapter] API Error (Status: #{status}). Max retries reached. Body: #{inspect(body)}")
          {:error, {:api_error, status, body}}
        end

      {:error, reason} ->
        if retry_count < 3 do
          Logger.error("[GeminiAdapter] Network/Timeout Error: #{inspect(reason)}. Retrying in 5000ms... (Attempt #{retry_count + 1})")
          Process.sleep(5000)
          make_request_with_retry(endpoint, req_params, retry_count + 1)
        else
          Logger.error("[GeminiAdapter] Network/Timeout Error: #{inspect(reason)}. Max retries reached.")
          {:error, {:network_error, reason}}
        end
    end
  end

  @impl true
  def embed(_text, _opts), do: {:error, :not_implemented}

  # --- Private Functions ---

  defp config do
    Application.get_env(:acn, :ai, [])[:gemini] ||
      [
        model: "gemini-3.1-flash-lite-preview"
      ]
  end

  @doc false
  def build_request_payload(messages, tools, config, opts) do
    # Convert messages to Gemini format
    # user request: ignore system instructions and pass full profile as user text
    gemini_contents = convert_messages_to_gemini(messages)
    
    enable_thinking = opts[:enable_thinking] || config[:enable_thinking] || false
    
    generation_config = %{
      "temperature" => opts[:temperature] || 1.0,
      "maxOutputTokens" => opts[:max_tokens] || config[:max_tokens] || 16000
    }
    
    generation_config = if enable_thinking do
      Map.put(generation_config, "thinkingConfig", %{"includeThoughts" => true})
    else
      generation_config
    end

    # Gemini requires at least one message in contents.
    # If empty (unlikely with system->user conversion), inject dummy.
    gemini_contents = if gemini_contents == [] do
      [%{"role" => "user", "parts" => [%{"text" => "Please proceed."}]}]
    else
      gemini_contents
    end

    base_payload = %{
      "contents" => gemini_contents,
      "generationConfig" => generation_config
    }
    
    # Add tools if provided
    if tools != nil and tools != [] do
      # Smart mode selection based on tool purpose:
      # - Use ANY for strict functional tools (must call): legislation, verdict, blueprint, identity
      # - Use AUTO for planning/reasoning tools: allows model to generate content first
      tool_names = Enum.map(tools, fn t -> t["name"] || t[:name] end)
      strict_tools = ["submit_legislation", "submit_verdict", "submit_blueprint", "mkdir", "touch", 
                      "set_node_identity", "submit_chronicle", "write_to_file", "submit_plan"]
      mode = opts[:tool_choice] || (if Enum.any?(tool_names, fn name -> name in strict_tools end), do: "ANY", else: "AUTO")
      
      base_payload
      |> Map.put("tools", [%{"functionDeclarations" => wrap_tools(tools)}])
      |> Map.put("toolConfig", %{"functionCallingConfig" => %{"mode" => mode}})
    else
      base_payload
    end
  end

  @doc false
  def convert_messages_to_gemini(messages) do
    # Gemini uses "user" and "model" roles.
    # We treat "system" messages as "user" messages to force them into the conversation flow
    # instead of using the separate systemInstruction field which can weak-frame the model.
    
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      
      gemini_role = case role do
        "assistant" -> "model"
        "tool" -> "function"
        "system" -> "user"  # FORCE SYSTEM TO USER
        _ -> "user"
      end
      
      # Handle tool calls in assistant messages
      tool_calls = msg[:tool_calls] || msg["tool_calls"]
      
      parts = cond do
        tool_calls && length(tool_calls) > 0 ->
          # Convert tool calls to Gemini function call format
          Enum.map(tool_calls, fn call ->
            func = call["function"]
            # Ensure args are a map
            args = if is_binary(func["arguments"]) do
               case Jason.decode(func["arguments"]) do
                  {:ok, decoded} -> decoded
                  _ -> %{} # Fallback
               end
            else
               func["arguments"]
            end
            
            %{
              "functionCall" => %{
                "name" => func["name"],
                "args" => args
              }
            }
          end)
        
        msg[:name] || msg["name"] ->
          # This is a tool response
          [%{
            "functionResponse" => %{
              "name" => msg[:name] || msg["name"],
              "response" => %{
                "content" => content
              }
            }
          }]
        
        true ->
          # Regular text content
          [%{"text" => content}]
      end
      
      %{
        "role" => gemini_role,
        "parts" => parts
      }
    end)
  end

  @doc false
  def wrap_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool["name"] || tool[:name],
        "description" => tool["description"] || tool[:description],
        "parameters" => tool["parameters"] || tool[:parameters]
      }
    end)
  end

  @doc false
  def parse_response({:error, _} = error), do: error
  def parse_response(body) do
    # Handle both single response (Map) and streaming response (List)
    # This prevents the ArgumentError when using streamGenerateContent without stream handling.
    response_data = if is_list(body), do: List.first(body), else: body
    
    candidates = response_data["candidates"]
    
    if is_nil(candidates) or length(candidates) == 0 do
      Logger.error("[GeminiAdapter] No candidates in response: #{inspect(body)}")
      {:error, :invalid_response}
    else
      candidate = List.first(candidates)
      content_data = candidate["content"]
      parts = content_data["parts"] || []
      finish_reason = candidate["finishReason"]
      
      # Extract text content, thinking, and function calls
      {text_content, thinking_content, tool_calls} = extract_content_and_tools(parts)
      
      # Debug logging
      log_response(text_content, tool_calls, thinking_content)

      # Build response struct
      response = %Response{
        content: text_content,
        thinking: thinking_content,
        tool_calls: tool_calls,
        finish_reason: finish_reason,
        token_usage: parse_token_usage(response_data)
      }

      {:ok, response}
    end
  end
  
  defp extract_content_and_tools(parts) do
    text_parts = Enum.filter(parts, fn part -> Map.has_key?(part, "text") end)
    function_parts = Enum.filter(parts, fn part -> Map.has_key?(part, "functionCall") end)
    thought_parts = Enum.filter(parts, fn part -> 
      Map.has_key?(part, "thought") or Map.has_key?(part, "reasoning_content") 
    end)
    
    text_content = if length(text_parts) > 0 do
      Enum.map_join(text_parts, "\n", fn part -> part["text"] end)
    else
      ""
    end

    thinking_content = if length(thought_parts) > 0 do
      Enum.map_join(thought_parts, "\n", fn part -> 
        part["thought"] || part["reasoning_content"] 
      end)
    else
      nil
    end
    
    tool_calls = if length(function_parts) > 0 do
      Enum.map(function_parts, fn part ->
        func_call = part["functionCall"]
        %{
          "id" => "call_#{:erlang.unique_integer([:positive])}",
          "type" => "function",
          "function" => %{
            "name" => func_call["name"],
            "arguments" => Jason.encode!(func_call["args"])
          }
        }
      end)
    else
      nil
    end
    
    {text_content, thinking_content, tool_calls}
  end

  defp parse_token_usage(body) do
    usage = body["usageMetadata"]
    
    if usage do
      %{
        prompt_tokens: usage["promptTokenCount"] || 0,
        completion_tokens: usage["candidatesTokenCount"] || 0,
        total: usage["totalTokenCount"] || 0
      }
    else
      %{total: 0}
    end
  end

  defp log_request(payload, tools, config) do
    IO.puts("\n\n🟢 [Gemini Input] ================================================")
    IO.puts("Model: #{config[:model] || "gemini-3.1-flash-lite-preview"}")
    IO.puts("Endpoint: Google Gemini API")
    
    if tools != nil and tools != [] do
      tool_names = Enum.map_join(tools, ", ", &(&1["name"] || &1[:name]))
      IO.puts("✅ Function Calling Enabled: #{length(tools)} tools (#{tool_names})")
    else
      IO.puts("⚠️ No tools provided")
    end

    if payload["systemInstruction"] do
      IO.puts("📜 System Instruction:")
      IO.puts(get_in(payload, ["systemInstruction", "parts", Access.at(0), "text"]))
    end

    contents = payload["contents"] || []
    IO.puts("--- Messages Sent (#{length(contents)}) ---")
    Enum.each(contents, fn msg ->
      role = String.upcase(msg["role"] || "UNKNOWN")
      parts = msg["parts"] || []
      
      # Extract text from parts
      text = parts
        |> Enum.filter(&Map.has_key?(&1, "text"))
        |> Enum.map_join(" ", &(&1["text"]))
      
      if text != "" do
        IO.puts("[#{role}]: #{text}")
      end
    end)
    IO.puts("==================================================================\n")
  end

  defp log_response(content, tool_calls, thinking) do
    IO.puts("\n\n🟣 [Gemini Output] ===============================================")

    if thinking && thinking != "" do
      IO.puts("💭 Reasoning:")
      IO.puts(thinking)
      IO.puts("------------------------------------------------------------------")
    end

    if tool_calls && length(tool_calls) > 0 do
      IO.puts("🔧 Tool Calls Detected (#{length(tool_calls)}):")
      Enum.each(tool_calls, fn call ->
        func = call["function"]
        IO.puts("  - #{func["name"]}(#{func["arguments"]})")
      end)
    end
    
    if content && content != "" do
      IO.puts("📝 Content:")
      IO.puts(content)
    end
    
    IO.puts("==================================================================\n")
  end
end
