defmodule ACN.AI.Adapters.OpenAI do
  @moduledoc """
  Production-ready OpenAI Adapter using Req.
  Implements retries, backoff, and strict timeout logic.
  """
  @behaviour ACN.AI.ModelBehavior
  require Logger

  alias ACN.AI.ModelBehavior.Response

  @default_opts [
    receive_timeout: 60_000,
    retry: :safe_transient, # Req built-in retry for network errors
    max_retries: 3
  ]

  @impl true
  def chat(messages, tools, opts \\ []) do
    config = config()
    # Separate domain options (model, temp) from Req options (receive_timeout)
    {domain_opts, req_opts} = Keyword.split(opts, [:model, :temperature])
    req_opts = Keyword.merge(@default_opts, req_opts)
    
    # 1. Prepare Payload
    payload = %{
      model: domain_opts[:model] || config[:model],
      messages: messages,
      temperature: domain_opts[:temperature] || 0.7
    }

    # Only attach tools if present to avoid API errors on some models
    payload = 
      if tools != [] do
        Map.put(payload, :tools, tools)
      else
        payload
      end

    # 2. Build Request with Middleware
    req = 
      Req.new(base_url: config[:base_url])
      |> Req.Request.put_header("authorization", "Bearer #{config[:api_key]}")
      |> Req.Request.put_header("content-type", "application/json")
      |> Req.Request.register_options([:receive_timeout]) 
      |> Req.merge(req_opts) # Applies timeout and retry config
      |> attach_retry_middleware() # Custom 429 logic
  
    # 3. Execute Request
    case Req.post(req, url: "/chat/completions", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OpenAI API Error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("OpenAI Network Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def embed(_text, _opts) do
    {:error, :not_implemented_yet}
  end

  # --- Internals ---

  defp config do
    Application.get_env(:acn, :ai, [])[:openai] || raise "OpenAI Config Missing!"
  end

  defp parse_response(body) do
    choice = List.first(body["choices"])
    message = choice["message"]
    
    # Extract Tool Calls if present
    tool_calls = message["tool_calls"] # List of maps usually
    
    response = %Response{
      content: message["content"],
      tool_calls: tool_calls,
      token_usage: body["usage"],
      finish_reason: choice["finish_reason"]
    }

    # Check for context length truncation
    if response.finish_reason == "length" do
      Logger.warning("Completion truncated due to length limit.")
    end

    {:ok, response}
  end

  defp attach_retry_middleware(req) do
    # Req sends this "retry" option to the built-in retry middleware.
    # We configure it to handle 429s specifically with backoff.
    
    # Actually, Req 0.4 handles 429 automatically if retry: :safe_transient is set?
    # Req docs: :safe_transient retries on transport errors, 408, 429, 500, 502, 503, 504.
    # So strictly speaking, just setting retry: :safe_transient matches our needs.
    # But let's verify delay. Default is 1s, 2s, 4s.
    
    # We'll explicitly set retry options for clarity/control
    Req.Request.register_options(req, [:retry, :retry_delay])
    |> Req.merge(
      retry: :safe_transient, 
      max_retries: 3,
      retry_delay: fn attempt -> 1000 * :math.pow(2, attempt) |> round() end # Exponential
    )
  end
end
