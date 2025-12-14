defmodule ACN.Core.Worksheet do
  @moduledoc """
  Formalizes the Agent's Memory/Workspace.
  Consists of typed Slots containing artifacts (code, plans, text).
  """
  
  defmodule Slot do
    @type t :: %__MODULE__{
      content: any(),
      type: atom(),    # :code | :plan | :text | :rule
      hash: String.t(),
      timestamp: integer()
    }
    defstruct [:content, :type, :hash, :timestamp]
    
    def new(content, type) do
      %__MODULE__{
        content: content,
        type: type,
        hash: :crypto.hash(:sha256, to_string(content)) |> Base.encode16(),
        timestamp: System.system_time(:second)
      }
    end
  end

  @type t :: %__MODULE__{
    slots: %{String.t() => Slot.t()}
  }
  defstruct slots: %{}

  def new do
    %__MODULE__{slots: %{}}
  end
  
  def put(%__MODULE__{} = ws, key, content, type \\ :text) do
    slot = Slot.new(content, type)
    new_slots = Map.put(ws.slots, key, slot)
    %{ws | slots: new_slots}
  end

  def get(%__MODULE__{} = ws, key) do
    Map.get(ws.slots, key)
  end

  def to_map(%__MODULE__{} = ws) do
    # Returns a simple map of {key => content} for easier consumption
    Enum.reduce(ws.slots, %{}, fn {k, slot}, acc ->
      Map.put(acc, k, slot.content)
    end)
  end
end
