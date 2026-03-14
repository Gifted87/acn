defmodule Mix.Tasks.Acn.InitMemory do
  use Mix.Task
  require Logger

  @shortdoc "Initializes connection to ACMS"

  def run(_) do
    Mix.Task.run("app.start")
    Logger.info("Checking ACMS connection...")

    case ACN.Infrastructure.MemoryClient.check_connection() do
      :ok ->
        IO.puts("✓ ACMS is online and healthy")
      {:error, reason} ->
        IO.puts("✗ ACMS connection failed: #{inspect reason}")
        IO.puts("  Make sure ACMS is running at http://localhost:4000")
    end
  end
end
