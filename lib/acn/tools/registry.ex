defmodule ACN.Tools.Registry do
  @moduledoc """
  Maps string tool names (from YAML profiles) to Elixir Modules.
  Serves as the central directory for all available capabilities.
  """
  
  # Static mapping of tool names to modules
  # As we refactor, we will populate this map
  @tools %{
    "fs_write" => ACN.Tools.FileSystem.Write,
    "read_file" => ACN.Tools.FileSystem.Read,
    "add_plan_node" => ACN.Tools.Planning.AddNode,
    "link_dependency" => ACN.Tools.Planning.LinkDependency,
    "upstream_merge" => ACN.Tools.Lattice.UpstreamMerge,
    "submit_fact" => ACN.Tools.Lattice.SubmitFact,
    
    # Memory Tools
    "query_wisdom" => ACN.Tools.Memory.QueryWisdom,
    # "ingest_fact" => ACN.Tools.Memory.IngestFact,
    "set_node_identity" => ACN.Tools.Supervisor.Identity,
    "submit_legislation" => ACN.Tools.Governance.SubmitLegislation,
    "submit_verdict" => ACN.Tools.Governance.SubmitVerdict,
    "submit_mediation" => ACN.Tools.Governance.SubmitMediation,
    "submit_execution_plan" => ACN.Tools.Planning.SubmitExecutionPlan,

    "dispatch_intent" => ACN.Tools.Communication.DispatchIntent,
    "submit_blueprint" => ACN.Tools.Governance.SubmitBlueprint,

    "write_to_file" => ACN.Tools.FileSystem.Write,
    "touch" => ACN.Tools.FileSystem.Touch,
    "mkdir" => ACN.Tools.FileSystem.Mkdir,
    "submit_plan" => ACN.Tools.Planning.SubmitPlan,
    "submit_chronicle" => ACN.Tools.Communication.SubmitChronicle,
    "submit_strategy" => ACN.Tools.Strategy.SubmitStrategy
  }

  @doc """
  Resolves a list of tool names to their implementation modules.
  Raises if a tool name is unknown (Fail Fast).
  """
  @spec lookup_all(list(String.t())) :: list(module())
  def lookup_all(names) do
    Enum.map(names, &lookup!/1)
  end

  @doc """
  Resolves a single tool name to its module.
  """
  @spec lookup!(String.t()) :: module()
  def lookup!(name) do
    case Map.fetch(@tools, name) do
      {:ok, module} -> module
      :error -> raise "CRITICAL: Tool '#{name}' requested but not registered in ACN.Tools.Registry!"
    end
  end
  
  # For dynamic registration later if needed (Phase 2+)
end
