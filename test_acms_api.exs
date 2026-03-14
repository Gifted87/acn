# test_acms_api.exs
require Logger

Mix.Task.run("app.start")

alias ACN.Infrastructure.MemoryClient
alias ACN.Core.Artifacts.DBC

IO.puts "--- Testing ACMS Ingestion ---"
dbc = %DBC{
  id: UUID.uuid4(),
  fact_text: "The primary decorative memory statement for testing.",
  author_id: "test_bot",
  timestamp: DateTime.utc_now(),
  verifier_id: "test_verifier",
  artifact_hash: "abc123hash",
  provenance_data: %{
    "source" => "manual_test",
    "trust_score" => 0.95
  }
}

case MemoryClient.ingest(dbc) do
  {:ok, node_id} ->
    IO.puts "✓ Ingestion successful! Node ID: #{node_id}"
  {:error, reason} ->
    IO.puts "✗ Ingestion failed: #{inspect reason}"
end

IO.puts "\n--- Testing ACMS Query ---"
case MemoryClient.query("decorative memory", 5) do
  {:ok, results} ->
    IO.puts "✓ Query successful! Found #{length(results)} results."
    Enum.each(results, fn r ->
      IO.puts "  - [Score: #{Float.round(r.score, 2)}] #{r.fact_text}"
    end)
  {:error, reason} ->
    IO.puts "✗ Query failed: #{inspect reason}"
end
