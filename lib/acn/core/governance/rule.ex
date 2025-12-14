defmodule ACN.Core.Governance.Rule do
  @moduledoc """
  Defines a specific constraint or directive for the Agent.
  """
  
  @type t :: %__MODULE__{
    id: String.t(),
    text: String.t(),
    source_node_id: String.t() | :master,
    priority: integer(), # 0-100. 100 = Master/Immutable.
    immutable: boolean()
  }
  
  defstruct [:id, :text, :source_node_id, :priority, :immutable]

  def new(id, text, source, priority) do
    %__MODULE__{
      id: id,
      text: text,
      source_node_id: source,
      priority: priority,
      immutable: priority >= 100
    }
  end
end

defmodule ACN.Core.Governance do
  @moduledoc """
  Central Governance Definitions.
  """
  alias ACN.Core.Governance.Rule

  def master_rules do
    [
      Rule.new("security_01", "Do not expose private keys or secrets.", :master, 100),
      Rule.new("security_02", "Verify all file paths before writing.", :master, 100),
      Rule.new("sys_01", "Communication must use JSON format.", :master, 100)
    ]
  end
end
