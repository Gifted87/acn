defmodule ACN.Agents.EnclaveSupervisor do
  use Supervisor, restart: :transient
  require Logger

  def start_link(args) do
    node_id = args[:node_id] || "unknown_node"
    Supervisor.start_link(__MODULE__, args, name: via_tuple(node_id))
  end

  defp via_tuple(node_id) do
    ACN.Core.NodeRegistry.via_tuple(:supervisor, "#{node_id}_enclave")
  end

  @impl true
  def init(args) do
    node_id = args[:node_id]

    children = [
      {ACN.Agents.Controller, [node_id: node_id]},
      {ACN.Agents.TaskManager, [node_id: node_id]},
      {ACN.Agents.Actuator, [node_id: node_id]},
      {ACN.Agents.Messenger, [node_id: node_id]},
      {ACN.Agents.LiveWire, [node_id: node_id]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
