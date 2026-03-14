defmodule ACN.AI.Adapters.OpenAIAdapter do
  @moduledoc """
  Adapter for OpenAI-compatible APIs (e.g., DashScope's Qwen-Flash).
  Implements native function calling without Python transpilation.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger
  alias ACN.AI.ModelBehavior.Response

  # Match Ollama timeout for consistency
  @default_opts [receive_timeout: 300_000]

  @impl true
  def chat(messages, tools, opts \\ []) do
    config = config()
    req_opts = Keyword.merge(@default_opts, opts)

    # Validate API key
    api_key = config[:api_key]
    if is_nil(api_key) or api_key == "" do
      Logger.error("[OpenAIAdapter] Missing API key. Set DASHSCOPE_API_KEY environment variable.")
      {:error, :missing_api_key}
    else
      do_chat(api_key, messages, tools, config, req_opts)
    end
  end

  defp do_chat(api_key, messages, tools, config, req_opts) do

    # Build request payload
    payload = build_request_payload(messages, tools, config, req_opts)
    
    # Debug logging
    log_request(payload, tools)

    # Make API call
    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    endpoint = "#{config[:base_url]}/chat/completions"
    
    Logger.info("[OpenAIAdapter] Calling #{endpoint} (Timeout: #{req_opts[:receive_timeout]}ms)...")

    case Req.post(endpoint,
           json: payload,
           headers: headers,
           receive_timeout: req_opts[:receive_timeout],
           finch: ACN.HTTPClient) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.info("[OpenAIAdapter] Successfully received response.")
        parse_response(body)

      {:ok, %Req.Response{status: 401, body: body}} ->
        Logger.error("[OpenAIAdapter] Authentication failed. Invalid API key.")
        {:error, {:auth_error, body}}

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.error("[OpenAIAdapter] Rate limit exceeded.")
        {:error, {:rate_limited, body}}

      {:ok, %Req.Response{status: 503, body: body}} ->
        Logger.error("[OpenAIAdapter] Service unavailable.")
        {:error, {:service_unavailable, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[OpenAIAdapter] API Error: #{status}")
        {:error, {:api_error, status, body}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        Logger.error("[OpenAIAdapter] Request timeout. Model may be taking too long.")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("[OpenAIAdapter] Network error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def embed(_text, _opts), do: {:error, :not_implemented}

  # --- Private Functions ---

  defp config do
    Application.get_env(:acn, :ai, [])[:openai] ||
      [
        base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        model: "qwen-flash"
      ]
  end

  @doc false
  def build_request_payload(messages, tools, config, opts) do
    base_payload = %{
      # Enable internal reasoning output for Qwen (DashScope)
      "enable_thinking" => opts[:enable_thinking] || config[:enable_thinking] || true,
      model: opts[:model] || config[:model] || "qwen-flash",
      messages: messages,
      temperature: opts[:temperature] || 1
    }

    # Add tools if provided
    if tools != nil and tools != [] do
      Map.merge(base_payload, %{
        tools: wrap_tools(tools),
        tool_choice: "auto"
      })
    else
      base_payload
    end
  end

  @doc false
  def wrap_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool["name"] || tool[:name],
          "description" => tool["description"] || tool[:description],
          "parameters" => tool["parameters"] || tool[:parameters]
        }
      }
    end)
  end

  @doc false
  def parse_response(body) do
    choice = List.first(body["choices"])
    
    if is_nil(choice) do
      Logger.error("[OpenAIAdapter] No choices in response: #{inspect(body)}")
      {:error, :invalid_response}
    else
      message = choice["message"]
      content = message["content"]
      thinking = message["reasoning_content"] || message["thought"]
      tool_calls = message["tool_calls"]
      finish_reason = choice["finish_reason"]

      # Debug logging
      log_response(content, tool_calls, thinking)

      # Build response struct
      response = %Response{
        content: content,
        thinking: thinking,
        tool_calls: tool_calls,
        finish_reason: finish_reason,
        token_usage: parse_token_usage(body)
      }

      {:ok, response}
    end
  end

  defp parse_token_usage(body) do
    usage = body["usage"]
    
    if usage do
      %{
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total: usage["total_tokens"] || 0
      }
    else
      %{total: 0}
    end
  end

  defp log_request(payload, tools) do
    IO.puts("\n\n🟢 [OpenAI Input] ================================================")
    IO.puts("Model: #{payload.model}")
    IO.puts("Endpoint: DashScope (Qwen-Flash)")
    
    if tools != nil and tools != [] do
      tool_names = Enum.map_join(tools, ", ", &(&1["name"] || &1[:name]))
      IO.puts("✅ Function Calling Enabled: #{length(tools)} tools (#{tool_names})")
    else
      IO.puts("⚠️ No tools provided")
    end

    IO.puts("--- Messages Sent (#{length(payload.messages)}) ---")
    Enum.each(payload.messages, fn msg ->
      role = String.upcase(msg[:role] || msg["role"] || "UNKNOWN")
      content = msg[:content] || msg["content"] || ""
      IO.puts("[#{role}]: #{content}")
    end)
    IO.puts("==================================================================\n")
  end

  defp log_response(content, tool_calls, thinking) do
    IO.puts("\n\n🟣 [OpenAI Output] ===============================================")
    
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
