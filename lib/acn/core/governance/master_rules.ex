defmodule ACN.Core.Governance.MasterRules do
  @moduledoc """
  Defines the immutable Master Rules for the ACN.
  These rules interact with the Legislator to ensure safety and security.
  Priority: 0 (Highest)
  """

  def get_rules do
    [
      "Safety: Do not use `rm -rf` or destructive commands without explicit user approval.",
      "Security: Zero-Trust Enforcement. All sensitive actions require a valid Token with appropriate scope.",
      "Network: No external network access allowed outside of the ACMS (Agent Communication & Memory System) channels.",
      "Data: All created files must reside within the assigned workspace directory.",
      "Concurrency: Avoid race conditions in GenServer state updates; use synchronous calls/casts appropriately."
    ]
  end
end
