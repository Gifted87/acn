# Verification Script for Synthesizer Agent
alias ACN.Core.NodeRegistry

IO.puts("--- Synthesizer Agent Test ---")

synthesizer = NodeRegistry.lookup(:synthesizer)

# 1. Trigger Finalization
IO.puts("1. Triggering Finalization...")
# passing dummy data
GenServer.cast(
  synthesizer, 
  {:finalize_task, "ab34ef", "Created a Login Module", "agent_007"}
)

# 2. Monitor Logs
IO.puts("2. Waiting for network attempt and shutdown request...")
# Attempting network call (will fail) then shutdown
Process.sleep(1000)

IO.puts("--- Test Complete (Check Logs for 'ACMS Ingest Failed' and Router Warning for :supervisor) ---")
