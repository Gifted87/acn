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
      "Containment: All file operations must be strictly within the assigned workspace directory.",
      "PRODUCTION READINESS: WHAT IS BEING BUILT IS A PRODUCTION READY SYSTEM AND THUS ALL COMPONENTS MUST BE PAINSTAKINGLY AND CONCRETELY IMPLEMENTED IN CODE!!!! LEGISLATORS MUST INCLUDE THIS IN THEIR RULES AND THE JUDGE MUST INSTANTLY DISQUALIFY ANY AGENT THAT GOES AGAINST THIS RULE."
    ]
  end
end
