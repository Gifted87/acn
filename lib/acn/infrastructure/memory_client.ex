defmodule ACN.Infrastructure.MemoryClient do
  @moduledoc """
  Client for the Adaptive Content Management System (ACMS) backed by Qdrant.
  Handles Vector Ingestion and Semantic Search.
  """
  require Logger
  alias ACN.Core.Artifacts.DBC
  alias ACN.AI.Embedder

  @collection "acms_facts"

  defp config do
    config = Application.get_env(:acn, :memory, [])
    base_url = config[:qdrant_url] || "http://localhost:6333"
    api_key = config[:qdrant_key]

    [base_url: base_url, api_key: api_key]
  end

  @doc """
  Ingests a Digital Birth Certificate (DBC) into the Vector DB.
  Generates the embedding locally before pushing.
  """
  def ingest(%DBC{} = dbc) do
    conf = config()
    url = "#{conf[:base_url]}/collections/#{@collection}/points"
    headers = if k = conf[:api_key], do: [{"api-key", k}], else: []

    # 1. Generate Vector
    case Embedder.embed(dbc.fact_text) do
       {:ok, vector} ->
          # 2. Construct Qdrant Point
          vector_id = UUID.uuid4()

          payload = %{
             "points" => [
               %{
                 "id" => vector_id,
                 "vector" => vector,
                 "payload" => %{
                    "artifact_hash" => dbc.artifact_hash,
                    "fact_text" => dbc.fact_text,
                    "author_id" => dbc.author_id,
                    "verifier_id" => dbc.verifier_id,
                    "timestamp" => DateTime.to_iso8601(dbc.timestamp),
                    "type" => "dbc"
                 }
               }
             ]
          }

          # 3. Push to Qdrant
          case Req.post(url, json: payload, headers: headers) do
             {:ok, %Req.Response{status: 200}} ->
                Logger.info("ACMS Ingest Success: #{vector_id}")
                {:ok, vector_id}
             {:ok, %Req.Response{status: status, body: body}} ->
                Logger.error("ACMS Ingest Failed (#{status}): #{inspect(body)}")
                {:error, :qdrant_error}
             {:error, reason} ->
                Logger.error("ACMS Network Failure: #{inspect(reason)}")
                {:error, reason}
          end

       {:error, reason} ->
          Logger.error("Embedding Generation Failed: #{inspect(reason)}")
          {:error, :embedding_failed}
    end
  end

  @doc """
  Performs a semantic search.
  Returns list of matching DBC metadata.
  """
  def query(query_text, limit \\ 5) do
    conf = config()
    url = "#{conf[:base_url]}/collections/#{@collection}/points/search"
    headers = if k = conf[:api_key], do: [{"api-key", k}], else: []

    with {:ok, vector} <- Embedder.embed(query_text),
         {:ok, %Req.Response{status: 200, body: body}} <- Req.post(url, json: %{vector: vector, limit: limit, with_payload: true}, headers: headers) do

       results =
         body["result"]
         |> Enum.map(fn item ->
            payload = item["payload"]
            %{
              score: item["score"],
              fact_text: payload["fact_text"],
              artifact_hash: payload["artifact_hash"],
              vector_id: item["id"]
            }
         end)

       {:ok, results}
    else
       {:error, reason} -> {:error, reason}
       {:ok, resp} -> {:error, resp}
    end
  end

  @doc """
  Initializes the Qdrant Collection.
  """
  def init_collection do
    conf = config()
    url = "#{conf[:base_url]}/collections/#{@collection}"
    headers = if k = conf[:api_key], do: [{"api-key", k}], else: []

    # Check existence
    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200}} ->
         Logger.info("Collection #{@collection} exists.")
         :ok
      _ ->
         Logger.info("Creating Collection #{@collection}...")
         # Create
         body = %{
           "vectors" => %{
             "size" => 384,
             "distance" => "Cosine"
           }
         }
         case Req.put(url, json: body, headers: headers) do
            {:ok, %Req.Response{status: 200}} ->
               Logger.info("Collection Created.")
               :ok
            other ->
               {:error, other}
         end
    end
  end
end
