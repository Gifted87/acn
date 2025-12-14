defmodule ACN.Agents.Messenger.InternalCommand do
  defstruct [
    :source,
    :command,
    :target,
    params: %{}
  ]
end
