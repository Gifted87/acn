defmodule Mix.Tasks.Acn.InitMemory do
  use Mix.Task
  require Logger

  @shortdoc "Initializes the ACMS Qdrant Collection"

  def run(_) do
    Mix.Task.run("app.start")
    Logger.info("Initializing ACMS Memory...")

    case ACN.Infrastructure.MemoryClient.init_collection() do
      :ok ->
        Logger.info("Memory Initialization Complete.")
      {:error, reason} ->
        Logger.error("Memory Initialization Failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
