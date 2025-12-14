defmodule ACN.Infrastructure.Fact do
  @derive Jason.Encoder
  defstruct [
    :fact_text,
    :agent_id,
    description_payloads: [],
    acls: nil,
    provenance: %{}
  ]
end

defmodule ACN.Infrastructure.QueryPayload do
  @derive Jason.Encoder
  defstruct [
    :query_text,
    :query_vector,
    :target_regions,
    :as_of,
    agent_id: "anonymous",
    embedding_model: "all-MiniLM-L6-v2",
    max_results: 50,
    min_relevance: 0.4,
    reasoning_mode: "normal",
    system_mode: "normal"
  ]
end
