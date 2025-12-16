defmodule ACN.Application do
  @moduledoc false
  use Application

  alias ACN.Core.NodeRegistry

  @impl true
  def start(_type, _args) do
    # Define optional children based on config
    llm_children = 
      if Application.get_env(:acn, :enable_local_serving, false) do
        [ACN.AI.LLM.Serving] 
      else
        []
      end

    children = [
      # Infrastructure (Must start first)
      ACN.Infrastructure.ClusterManager,
      ACN.Infrastructure.StateBackup,
      ACN.Infrastructure.NetworkMonitor,

      # Core Registry & Monitors (Before agents)
      NodeRegistry.child_spec(),
      ACN.Core.NodeMonitor,
      ACN.Core.NodeSupervisor,

      # Phoenix PubSub (BEFORE agents that subscribe to it)
      {Phoenix.PubSub, name: ACN.PubSub},

      # Core Agents (After PubSub)
      ACN.Agents.LiveWire,
      ACN.Agents.Messenger,
      ACN.Agents.Controller,
      ACN.Agents.Specialist,
      ACN.Agents.Validator,
      ACN.Agents.Synthesizer,
      ACN.Agents.TaskManager,
      {ACN.Agents.Actuator, [public_key: nil]},
      ACN.Agents.SupervisorAgent,

      # AI Services
      ACN.AI.Embedder.Serving,
      {Task.Supervisor, name: ACN.AI.TaskSupervisor},

      # Phoenix Web (After agents)
      ACNWeb.Endpoint
    ] ++ llm_children

    opts = [strategy: :one_for_one, name: ACN.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
