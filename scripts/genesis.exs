# Genesis Launch Script
# This script initiates the first ACN Node and triggers the complete lifecycle

# 1. Ensure the application is running
{:ok, _} = Application.ensure_all_started(:acn)

# 2. Define the First Thought
genesis_payload = %{
  task: "Build a Hello World Elixir Module",
  task_type: :leaf, # Will trigger LEAF identity (not :manager)
  parent_node: nil    # Root Node
}

# 3. Wake the Supervisor (The Big Bang)
IO.puts("🚀 INITIATING GENESIS SEQUENCE...")
IO.puts("   Task: #{genesis_payload.task}")
IO.puts("   Type: #{genesis_payload.task_type}")
IO.puts("")

GenServer.cast(
  ACN.Core.NodeRegistry.lookup(:supervisor), 
  {:init_node, genesis_payload}
)

IO.puts("Genesis triggered. Observing autonomous lifecycle...")
IO.puts("(Press Ctrl+C twice to exit)")
IO.puts("")

# 4. Keep the script alive to see logs
Process.sleep(:infinity)
