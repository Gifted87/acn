# test_exact_payload.exs
require Logger

Mix.Task.run("app.start")

# Use raw HTTPoison/Req to send the EXACT payload from the user request
url = "http://localhost:4000/api/v1/ingest"
headers = [
  {"Content-Type", "application/json"},
  {"x-agent-id", "agent_name"}
]

body = %{
  "fact_text" => "The primary declarative memory statement.",
  "agent_id" => "agent_name",
  "acls" => %{
    "read" => ["public", "group_a"],
    "write" => ["root"]
  },
  "provenance" => %{
    "source" => "manual_entry",
    "trust_score" => 0.9
  },
  "description_payloads" => [
    %{ "type" => "text", "content" => "Supporting detail..." },
    %{ "type" => "code", "language" => "elixir", "content" => "def run, do: :ok" },
    %{ "type" => "number", "value" => 42, "unit" => "count" },
    %{ "type" => "link", "uri" => "http://example.com", "description" => "Ref" },
    %{ "type" => "object", "object_type" => "sensor_data", "data" => %{ "temp" => 23 } }
  ]
}

IO.puts "Sending exact payload from spec..."
case Req.post(url, json: body, headers: headers) do
  {:ok, %Req.Response{status: status, body: response_body}} ->
    IO.puts "Status: #{status}"
    IO.inspect(response_body)
  {:error, reason} ->
    IO.puts "Error: #{inspect reason}"
end
