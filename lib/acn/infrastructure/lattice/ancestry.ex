defmodule ACN.Infrastructure.Lattice.NodeInfo do
  @moduledoc """
  Metadata about a single node in the lineage.
  """
  @type t :: %__MODULE__{
    id: String.t(),
    pid: pid(),
    node_address: atom(),
    role: atom()
  }
  defstruct [:id, :pid, :node_address, :role]
end

defmodule ACN.Infrastructure.Lattice.Ancestry do
  @moduledoc """
  Holds the resolved lineage of a node.
  """
  alias ACN.Infrastructure.Lattice.NodeInfo
  
  @type t :: %__MODULE__{
    parent: NodeInfo.t() | nil,
    grandparent: NodeInfo.t() | nil,
    great_grandparent: NodeInfo.t() | nil
  }
  defstruct [:parent, :grandparent, :great_grandparent]
end
