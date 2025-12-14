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
    "generate_gm_query" => ACN.Tools.Memory.GenerateQuery,
    "report_static_status" => ACN.Tools.Validation.Static,
    "upstream_merge" => ACN.Tools.Lattice.UpstreamMerge,
    "generate_defect_report" => ACN.Tools.Validation.DefectReporting,
    "set_node_identity" => ACN.Tools.Supervisor.Identity
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
