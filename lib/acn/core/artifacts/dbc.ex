defmodule ACN.Core.Artifacts.DBC do
  @moduledoc """
  The Digital Birth Certificate (DBC).
  Strict schema for all permanent Artifacts in the ACN.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :artifact_hash, :fact_text, :timestamp, :author_id]
  defstruct [
    :id,            # UUID (DBC Unique ID)
    :artifact_hash, # SHA256 of the artifact content
    :fact_text,     # Natural Language Description (The Semantic Anchor)
    :acms_node_id,  # UUID (ACMS Node ID, nil if offline)
    :author_id,     # Agent ID
    :verifier_id,   # Validator ID
    :validation_proof, # Map (Evidence)
    :cost_metrics,  # %{tokens: N, time_ms: T}
    :constituents,  # List of Child DBC IDs (for Intermediate Nodes)
    :timestamp,     # DateTime (Creation Time)
    :provenance_data, # Map (Additional Context)
    :source_code,   # String (The actual implementation content)
    :full_path,     # String (Absolute path to the artifact)
    :filename       # String (Base name of the artifact file)
  ]

  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
