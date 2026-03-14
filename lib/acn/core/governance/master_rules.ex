defmodule ACN.Core.Governance.MasterRules do
  @moduledoc """
  Defines the immutable Master Rules for software generation.
  These rules are the "Constitution" of the Lattice.
  Priority: 0 (Highest)
  """

  def get_rules do
    [
      "Safety: No destructive file system operations (e.g. `rm -rf`, system deletion) allowed.",
      "Security: Do NOT hardcode secrets, API keys, or credentials. Use configuration injection.",
      "Privacy: No external network requests allowed from generated code. Localhost interaction only.",
      "Containment: All file operations must be strictly within the assigned workspace directory."
    ]
  end
end
