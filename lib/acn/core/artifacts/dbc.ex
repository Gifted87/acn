defmodule ACN.Core.Artifacts.DBC do
  @moduledoc """
  The Digital Birth Certificate (DBC).
  Strict schema for all permanent Artifacts in the ACN.
  """

  @enforce_keys [:id, :artifact_hash, :fact_text, :timestamp, :author_id]
  defstruct [
    :id,            # UUID (Global ID)
    :artifact_hash, # SHA-256 (File Content)
    :fact_text,     # Semantic Summary (LLM)
    :vector_id,     # UUID (Qdrant ID, nil if offline)
    :author_id,     # String
    :verifier_id,   # String (Validator)
    :validation_proof, # Map (Validator verdict, test output, proof of correctness)
    :cost_metrics,  # Map (Tokens, execution time, LiveWire data)
    :constituents,  # List of child DBC IDs (for intermediate nodes)
    :timestamp,     # DateTime
    :provenance_data # Map (Extra context)
  ]

  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
