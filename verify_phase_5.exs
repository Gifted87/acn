# verify_phase_5.exs
Application.ensure_all_started(:mnesia)
Application.ensure_all_started(:logger)
Application.ensure_all_started(:elixir_uuid)

alias ACN.Core.Security.TokenAuthority
alias ACN.Infrastructure.StateBackup

IO.puts "=== 1. Token Authority Verification ==="
{priv, pub} = TokenAuthority.generate_keypair()
IO.puts "Generated Keypair."

{:ok, token, _} = TokenAuthority.mint_token(priv, :fs_write, "/tmp/foo")
IO.puts "Minted Token: #{String.slice(token, 0, 20)}..."

case TokenAuthority.verify(token, pub, :fs_write, "/tmp/foo") do
  {:ok, claims} -> IO.puts "SUCCESS: Verified Token. Claims: #{inspect(claims)}"
  e -> IO.puts "FAILURE: Verify failed: #{inspect(e)}"
end

case TokenAuthority.verify(token, pub, :exec_cmd, "rm -rf /") do
  {:error, :invalid_scope} -> IO.puts "SUCCESS: Rejected invalid scope."
  {:error, :resource_mismatch} -> IO.puts "SUCCESS: Rejected resource mismatch."
  ok -> IO.puts "FAILURE: Allowed invalid scope/resource! #{inspect(ok)}"
end


IO.puts "\n=== 2. State Backup Verification ==="
# Start Backup GenServer manually if not running
case ACN.Infrastructure.StateBackup.start_link() do
  {:ok, _} -> IO.puts "Started StateBackup."
  {:error, {:already_started, _}} -> IO.puts "StateBackup already running."
  e -> IO.puts "Error starting StateBackup: #{inspect(e)}"
end

agent_id = "test_agent_#{UUID.uuid4()}"
state = %{foo: "bar", time: DateTime.utc_now()}

ACN.Infrastructure.StateBackup.backup(agent_id, state)
# Wait for cast
Process.sleep(100)

case ACN.Infrastructure.StateBackup.restore(agent_id) do
  {:ok, restored} ->
      if restored == state do
         IO.puts "SUCCESS: Restored state matches original."
      else
         IO.puts "FAILURE: State mismatch. Got: #{inspect(restored)}"
      end
  e -> IO.puts "FAILURE: Restore failed: #{inspect(e)}"
end

IO.puts "\n=== Phase 5 Verification Complete ==="
System.halt(0)
