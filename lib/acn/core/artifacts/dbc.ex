defmodule ACN.Core.Artifacts.DBC do
  @moduledoc """
  The Digital Birth Certificate (DBC).
  Strict schema for all permanent Artifacts in the ACN.
  """

  @derive {Jason.Encoder, except: [:source_code]}
  @enforce_keys [:id, :artifact_hash, :fact_text, :timestamp, :author_id]
  defstruct [
    # UUID (DBC Unique ID)
    :id,
    # SHA256 of the artifact content
    :artifact_hash,
    # Natural Language Description (The Semantic Anchor)
    :fact_text,
    # UUID (ACMS Node ID, nil if offline)
    :acms_node_id,
    # Agent ID
    :author_id,
    # Validator ID
    :verifier_id,
    # Map (Evidence)
    :validation_proof,
    # %{tokens: N, time_ms: T}
    :cost_metrics,
    # List of Child DBC IDs (for Intermediate Nodes)
    :constituents,
    # DateTime (Creation Time)
    :timestamp,
    # Map (Additional Context)
    :provenance_data,
    # String (The actual implementation content)
    :source_code,
    # String (Absolute path to the artifact)
    :full_path,
    # String (Base name of the artifact file)
    :filename
  ]

  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
