defmodule ACN.Core.Artifacts.ImmutableContext do
  @moduledoc """
  Defines the read-only context provided to the Specialist.
  Acts as "Lattice Memory".
  """

  defstruct [
    # Map of {file_path => content} from ancestors
    ancestral_memory: %{}, 
    
    # Tree/List of existing filenames in current/parent nodes
    codebase_map: [],
    
    # Raw wisdom text
    wisdom_context: ""
  ]
end
