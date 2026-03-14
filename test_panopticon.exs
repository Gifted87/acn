# Start the application
Application.ensure_all_started(:acn)

# Wait a moment for GenServers to boot
Process.sleep(500)

IO.puts("\n=== 1. Starting Panopticon State ===")
IO.inspect(ACN.Observability.Panopticon.snapshot())

IO.puts("\n=== 2. Simulating Task Manager Plan ===")
ACN.Observability.Panopticon.inject_intent("root_tm", 0, [
  %{id: "child_1", task: "Setup db"},
  %{id: "child_2", task: "Write API"}
])

IO.puts("\n=== 3. Simulating Telemetry Events ===")
phase_1_dbc = %ACN.Observability.MicroDBC{
  event_id: :crypto.strong_rand_bytes(16) |> Base.encode16(),
  node_id: "child_1",
  mat_path: "root.db",
  phase_from: :architecting,
  phase_to: :execution,
  hash: "hash123",
  autonomic: %{stress_level: 10.0}
}

phase_2_dbc = %ACN.Observability.MicroDBC{
  event_id: :crypto.strong_rand_bytes(16) |> Base.encode16(),
  node_id: "child_1",
  mat_path: "root.db",
  phase_from: :execution,
  phase_to: :completed,
  prev_hash: "hash123",
  hash: "hash456",
  autonomic: %{stress_level: 5.0}
}

Phoenix.PubSub.broadcast(ACN.PubSub, "acn:telemetry:all", {:telemetry_event, phase_1_dbc})
Phoenix.PubSub.broadcast(ACN.PubSub, "acn:telemetry:all", {:telemetry_event, phase_2_dbc})

# Give Panopticon a moment to process the async casts/infos
Process.sleep(500)

IO.puts("\n=== 4. Final Panopticon State ===")
final_state = ACN.Observability.Panopticon.snapshot()
IO.inspect(final_state)

if length(final_state.vertices) > 0 do
  IO.puts("\n[SUCCESS] Graph populated with #{length(final_state.vertices)} vertices and #{length(final_state.edges)} edges.")
end
