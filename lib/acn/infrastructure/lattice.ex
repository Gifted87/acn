defmodule ACN.Infrastructure.Lattice do
  @moduledoc """
  Helper module for distributed lattice operations.
  Handles RPC calls and remote data fetching transparently.
  """
  require Logger

  @doc """
  Fetches artifact content from a specific node or from the global shared state (mocked for now).
  If `source_node` matches `node()`, it reads directly.
  Otherwise, it uses RPC.
  """
  def fetch_artifact(hash_or_path, nil), do: fetch_artifact(hash_or_path, node())
  def fetch_artifact(path, source_node) when is_binary(path) do
    if source_node == node() do
      File.read(path)
    else
      Logger.debug("Lattice: Fetching remote artifact from #{inspect(source_node)}: #{path}")
      
      case :rpc.call(source_node, File, :read, [path], 5000) do
        {:ok, content} -> {:ok, content}
        {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
        {:error, reason} -> {:error, reason}
        error -> {:error, error}
      end
    end
  end

  @doc """
  Fetches the governance/context data from a parent node.
  """
  def fetch_ancestral_data(nil), do: {:error, :no_parent}
  def fetch_ancestral_data(parent_node) do
    if parent_node == node() do
      ACN.Agents.SupervisorAgent.get_public_context()
    else
      Logger.info("Lattice: Fetching ancestral data from #{inspect(parent_node)}")
      case :rpc.call(parent_node, ACN.Agents.SupervisorAgent, :get_public_context, [], 5000) do
        {:ok, data} -> {:ok, data}
        {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
        error -> {:error, error}
      end
    end
  end
end
