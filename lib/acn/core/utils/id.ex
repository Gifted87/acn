defmodule ACN.Core.Utils.ID do
  @moduledoc """
  Provides utilities for normalizing and slugifying task and node IDs.
  Ensures consistent string keys across the distributed system.
  """

  @doc """
  Normalizes a given ID into a slugified string.
  - Converts atoms to strings.
  - Downcases all characters.
  - Replaces whitespace and non-alphanumeric characters with underscores.
  - Trims balance underscores.
  """
  def normalize(id) when is_atom(id), do: normalize(Atom.to_string(id))
  def normalize(id) when is_binary(id) do
    id
    |> String.replace(~r/([a-z])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
  def normalize(id), do: normalize(to_string(id))
end
