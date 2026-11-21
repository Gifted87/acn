defmodule ACN.AI.Adapters.OpenAIAdapter do
  @moduledoc """
  Adapter for OpenAI-compatible Chat Completions APIs.
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

    req_opts =
      Keyword.merge(
        [receive_timeout: config[:request_timeout] || @default_opts[:receive_timeout]],
        opts
      )

    # Validate API key
    api_key = config[:api_key]

    if is_nil(api_key) or api_key == "" do
      Logger.error(
        "[OpenAIAdapter] Missing API key. Configure OPENAI_API_KEY_FILE or OPENAI_API_KEY."
      )

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

    Logger.info(
      "[OpenAIAdapter] Calling #{endpoint} (Timeout: #{req_opts[:receive_timeout]}ms)..."
    )

    case Req.post(endpoint,
           json: payload,
           headers: headers,
           receive_timeout: req_opts[:receive_timeout],
           finch: ACN.HTTPClient
         ) do
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
        base_url: "http://134.199.196.182:8000/v1",
        model: "qwen3.8-27b"
      ]
  end

  @doc false
  def build_request_payload(messages, tools, config, opts) do
    messages =
      messages
      |> normalize_multimodal_tool_results(config[:supports_images] != false)
      |> ensure_user_message()

    base_payload = %{
      model: config[:model] || opts[:model] || "qwen3.8-27b",
      messages: messages,
      temperature: opts[:temperature] || 1
    }

    # This is a DashScope extension, not part of the OpenAI-compatible schema.
    # Only send it when a caller explicitly configures it.
    thinking = Keyword.get(opts, :enable_thinking, config[:enable_thinking])

    base_payload =
      if is_boolean(thinking),
        do: Map.put(base_payload, "enable_thinking", thinking),
        else: base_payload

    # Add tools if provided
    if tools != nil and tools != [] do
      tool_choice =
        case Keyword.get(opts, :tool_choice, config[:tool_choice]) do
          "ANY" -> "required"
          "AUTO" -> "auto"
          "NONE" -> "none"
          choice when is_binary(choice) -> choice
          _ -> "auto"
        end

      base_payload
      |> Map.put(:tools, wrap_tools(tools))
      |> Map.put(:tool_choice, tool_choice)
      |> Map.put(:parallel_tool_calls, Keyword.get(opts, :parallel_tool_calls, true))
    else
      base_payload
    end
  end

  # Some OpenAI-compatible model servers (including this Qwen endpoint) require
  # a user-role query even when the application has placed the full task in the
  # system prompt. Preserve any real user message and add a minimal one only
  # for system-only conversations.
  defp ensure_user_message(messages) when is_list(messages) do
    has_initial_user_message? =
      messages
      |> Enum.take_while(fn
        %{role: role} when role in ["assistant", "tool"] -> false
        %{"role" => role} when role in ["assistant", "tool"] -> false
        _ -> true
      end)
      |> Enum.any?(fn
        %{role: role} when role in ["user", :user] -> true
        %{"role" => role} when role in ["user", :user] -> true
        _ -> false
      end)

    if has_initial_user_message? do
      messages
    else
      user_message = %{
        role: "user",
        content:
          "Follow the instructions in the system message, complete the requested task, and call the required tool when applicable."
      }

      case messages do
        [%{role: "system"} = system | rest] -> [system, user_message | rest]
        [%{"role" => "system"} = system | rest] -> [system, user_message | rest]
        _ -> [user_message | messages]
      end
    end
  end

  # Keep OpenAI's assistant/tool protocol intact, then expose screenshots as
  # user-role image content because the configured Qwen multimodal template
  # consumes image parts on user messages.
  defp normalize_multimodal_tool_results(messages, supports_images?) do
    Enum.flat_map(messages, fn
      %{role: "tool", content: content} = message when is_list(content) ->
        normalize_tool_content(message, content, supports_images?)

      %{"role" => "tool", "content" => content} = message when is_list(content) ->
        normalize_tool_content(message, content, supports_images?)

      message ->
        [message]
    end)
  end

  defp normalize_tool_content(message, content, supports_images?) do
    {images, text_parts} =
      Enum.split_with(content, fn
        %{"type" => "image_url"} -> true
        %{type: "image_url"} -> true
        _ -> false
      end)

    text =
      text_parts
      |> Enum.map(fn
        %{"text" => value} when is_binary(value) -> value
        %{text: value} when is_binary(value) -> value
        other -> inspect(other)
      end)
      |> Enum.join("\n")

    text =
      if images != [] and not supports_images? do
        [
          text,
          "[Screenshot omitted: this model endpoint accepts text only; use the DOM snapshot.]\n"
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      else
        text
      end

    normalized_tool_message =
      if Map.has_key?(message, :content),
        do: Map.put(message, :content, text),
        else: Map.put(message, "content", text)

    if images == [] or not supports_images? do
      [normalized_tool_message]
    else
      [normalized_tool_message, %{role: "user", content: text_parts ++ images}]
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
    IO.puts("Endpoint: OpenAI-compatible Chat Completions")

    if tools != nil and tools != [] do
      tool_names = Enum.map_join(tools, ", ", &(&1["name"] || &1[:name]))
      IO.puts("✅ Function Calling Enabled: #{length(tools)} tools (#{tool_names})")
    else
      IO.puts("⚠️ No tools provided")
    end

    IO.puts("--- Messages Sent (#{length(payload.messages)}) ---")

    Enum.each(payload.messages, fn msg ->
      role = String.upcase(msg[:role] || msg["role"] || "UNKNOWN")
      content = format_log_content(msg[:content] || msg["content"] || "")
      IO.puts("[#{role}]: #{content}")
    end)

    IO.puts("==================================================================\n")
  end

  defp format_log_content(content) when is_binary(content), do: content

  defp format_log_content(content) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{"type" => "image_url"} -> "[image attached]"
      %{type: "image_url"} -> "[image attached]"
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      other -> inspect(other, limit: 10)
    end)
  end

  defp format_log_content(content), do: inspect(content, limit: 20)

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
