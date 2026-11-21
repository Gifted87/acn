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
      {Finch, name: ACN.HTTPClient, pools: %{:default => [size: 200, count: 1]}},
      ACN.Infrastructure.ClusterManager,
      ACN.Infrastructure.StateBackup,
      ACN.Infrastructure.NetworkMonitor,
      ACN.Infrastructure.ACMSLimiter,
      ACN.Core.AuditBuffer,

      # Core Registry & Monitors (Before agents)
      NodeRegistry.child_spec(),
      ACN.Core.LatticeRegistry,
      ACN.Core.NodeMonitor,
      ACN.Core.NodeSupervisor,

      # Phoenix PubSub (BEFORE agents that subscribe to it)
      {Phoenix.PubSub, name: ACN.PubSub},

      # HSG Observability Layer
      ACN.Observability.Schema,
      ACN.Observability.Panopticon,

      # Root Supervisor (Responsible for starting the root enclave)
      # REMOVED: Genesis now dynamically spawns the root node via NodeSupervisor.
      # {ACN.Agents.SupervisorAgent, [node_id: "root"]},

      # AI Services
      ACN.AI.KeyRotator,
      ACN.JudicialBrowser,
      {Task.Supervisor, name: ACN.AI.TaskSupervisor},

      # Phoenix Web (After agents)
      ACNWeb.Endpoint
    ] ++ llm_children ++ (if Application.get_env(:acn, :enable_embeddings, false), do: [ACN.AI.Embedder.Serving], else: [])

    opts = [strategy: :one_for_one, name: ACN.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end
end
