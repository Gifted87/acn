defmodule ACN.Core.Router do
  require Logger
  alias ACN.Core.NodeRegistry

  def route(payload, {:local, agent_name}) do
    case NodeRegistry.lookup(agent_name) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        GenServer.cast(pid, payload)

      _ ->
        Logger.warning("Routing failed: Local agent #{inspect(agent_name)} not found.")
    end
  end

  def route(payload, {:sideways, topic}) do
    Registry.dispatch(ACN.Registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, payload)
      end
    end)
  end

  def route(_payload, _destination) do
    Logger.error("Unknown routing destination.")
  end
end
