# Start the application
Application.ensure_all_started(:acn)

IO.puts("\n=== 1. Starting Panopticon State ===")
IO.inspect(ACN.Observability.Panopticon.snapshot())

IO.puts("\n=== 2. Triggering Genesis (Creates root node & starts flow) ===")
# Generate a simple task that forces at least one phase transition
task = "Write a hello world python script in /tmp/hello.py"

case ACN.Genesis.ignite(task) do
  {:ok, _pid} -> 
    IO.puts("Genesis ignited. Waiting for trace events to propagate...")
    # Give the agents a moment to transition phases, run the LLM, and emit HSG events
    Process.sleep(5000)
    
  error -> 
    IO.puts("Failed to ignite: #{inspect(error)}")
end

IO.puts("\n=== 3. Final Panopticon State ===")
# We should now see vertices (agents, hashes) and edges (transitions)
snapshot = ACN.Observability.Panopticon.snapshot()
IO.inspect(snapshot)

# Check if it's still empty
if Enum.empty?(snapshot.vertices) do
  IO.puts("\n[ERROR] Graph is still empty. Emitter hooks might not be firing properly.")
else
  IO.puts("\n[SUCCESS] Graph populated with #{length(snapshot.vertices)} vertices and #{length(snapshot.edges)} edges.")
end
