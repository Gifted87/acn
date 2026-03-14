# Script to verify Gemini Adapter implementation
# Run with: mix run verify_gemini.exs

Logger.configure(level: :info)

IO.puts("--- Verifying Gemini Adapter Configuration ---")

config = Application.get_env(:acn, :ai)
gemini_config = config[:gemini]
default_adapter = config[:default_adapter]

IO.puts("Default Adapter: #{inspect(default_adapter)}")
IO.puts("Gemini Config: #{inspect(gemini_config)}")

if default_adapter == ACN.AI.Adapters.GeminiAdapter do
  IO.puts("✅ Default adapter is correctly set to GeminiAdapter.")
else
  IO.puts("❌ Default adapter IS NOT GeminiAdapter. It is: #{inspect(default_adapter)}")
end

if gemini_config[:model] == "gemini-2.5-flash-lite" do
  IO.puts("✅ Model is correctly set to gemini-2.5-flash-lite.")
else
  IO.puts("❌ Model is NOT set to gemini-2.5-flash-lite. It is: #{inspect(gemini_config[:model])}")
end

if gemini_config[:enable_thinking] == true do
  IO.puts("✅ Thinking is enabled in config.")
else
  IO.puts("❌ Thinking is NOT enabled in config.")
end

IO.puts("\n--- Attempting API Call (Standard Chat) ---")
messages = [%{role: "user", content: "Hello! If you can think, please output a thinking process then say hello."}]

try do
  case ACN.AI.Adapters.GeminiAdapter.chat(messages, []) do
    {:ok, response} ->
      IO.puts("\n✅ Success! Response received.")
      IO.puts("Content: #{response.content}")
      if response.thinking do
        IO.puts("💭 Thinking capture worked!")
        IO.puts(response.thinking)
      else
        IO.puts("⚠️ No thinking content captured (Model might not have produced it or parsing failed).")
      end
      
    {:error, reason} ->
       IO.puts("\n❌ API Call Failed: #{inspect(reason)}")
  end
rescue
  e -> IO.puts("\n❌ Crash during call: #{inspect(e)}")
end


IO.puts("\n--- Attempting Tool Use Verification ---")
tools = [
  %{
    "name" => "calculator",
    "description" => "A simple calculator",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "expression" => %{
          "type" => "string",
          "description" => "The mathematical expression to evaluate"
        }
      },
      "required" => ["expression"]
    }
  }
]

messages_tools = [%{role: "user", content: "Calculate 15 * 5 using the calculator tool."}]

try do
  case ACN.AI.Adapters.GeminiAdapter.chat(messages_tools, tools) do
    {:ok, response} ->
      IO.puts("\n✅ Tool Request Response received.")
      # IO.inspect(response) # Debug full response if needed
      
      if response.tool_calls && length(response.tool_calls) > 0 do
         IO.puts("✅ Tool Calls Detected: #{inspect(response.tool_calls)}")
         call = List.first(response.tool_calls)
         IO.puts("   Function: #{call["function"]["name"]}")
         IO.puts("   Arguments: #{inspect(call["function"]["arguments"])}")
      else
         IO.puts("❌ No tool calls returned! Response content: #{response.content}")
      end
      
    {:error, reason} ->
       IO.puts("\n❌ Tool API Call Failed: #{inspect(reason)}")
  end
rescue
  e -> IO.puts("\n❌ Crash during tool call: #{inspect(e)}")
end
