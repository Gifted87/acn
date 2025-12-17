defmodule ACN.Infrastructure.MemoryClient do
  @moduledoc """
  Client for the remote Associative Cognitive Memory System (CMS).
  
  This module acts as the bridge between the ACN (Agent/Client) and the 
  CMS (Brain/Server). It communicates exclusively via the CMS REST API.
  
  Unlike previous versions, this client performs NO local embedding generation.
  It offloads semantic indexing, storage, and Hebbian association to the CMS.
  """
  require Logger
  alias ACN.Core.Artifacts.DBC

  # Default to localhost:4000 if not configured, but ideally set via env var CMS_URL
  defp config do
    config = Application.get_env(:acn, :memory, [])
    base_url = config[:cms_url] || "http://localhost:4000"
    api_key = config[:cms_api_key] # Optional, for future auth

    [base_url: base_url, headers: build_headers(api_key)]
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}]
  defp build_headers(key), do: [{"content-type", "application/json"}, {"x-agent-key", key}]

  @doc """
  Ingests a Digital Birth Certificate (DBC) into the remote CMS.
  
  Maps the ACN's `DBC` struct to the CMS's expected Ingestion JSON schema.
  """
  def ingest(%DBC{} = dbc) do
    conf = config()
    url = "#{conf[:base_url]}/api/v1/ingest"

    # 1. Map DBC to CMS Payload (defined in CMS.Web / FIDValidator)
    # We treat the fact_text as the primary Text payload. 
    # If the DBC has specific cost metrics or provenance, we attach them as metadata.
    payloads = [
      %{"type" => "text", "content" => dbc.fact_text}
    ]
    
    # Add Code payload if it looks like code (simple heuristic or extend DBC to support it)
    # For now, we stick to the text fact.

    request_body = %{
      "fact_text" => dbc.fact_text,
      "agent_id" => "root",
      "description_payloads" => payloads,
      # Default ACLs: Public read, Author write
      "provenance" => Map.merge(dbc.provenance_data || %{}, %{
        "verifier_id" => dbc.verifier_id,
        "artifact_hash" => dbc.artifact_hash,
        "origin_timestamp" => DateTime.to_iso8601(dbc.timestamp)
      }),
      "acls" => ["public"]
    }

    # 2. Send to CMS
    case Req.post(url, json: request_body, headers: conf[:headers]) do
      {:ok, %Req.Response{status: 201, body: %{"node_id" => id}}} ->
        Logger.info("CMS Ingest Success. Node ID: #{id}")
        {:ok, id}

      {:ok, %Req.Response{status: 202, body: %{"meta_node_id" => id, "status" => "conflict_resolved"}}} ->
        Logger.info("CMS Ingest: Conflict Resolved via Dialectics. Meta-Node ID: #{id}")
        {:ok, id}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("CMS Rejected Ingest (#{status}): #{inspect(body)}")
        {:error, :cms_rejection}

      {:error, reason} ->
        Logger.error("CMS Network Failure: #{inspect(reason)}")
        {:error, :network_failure}
    end
  end

  @doc """
  Performs a semantic search against the remote CMS.
  
  The CMS handles the vectorization of the query text.
  """
  def query(query_text, limit \\ 5)

  # Guard against empty queries to prevent 400 Bad Request
  def query(query_text, _limit) when is_nil(query_text) or query_text == "" do
    Logger.warning("MemoryClient: Aborting query with empty text.")
    {:ok, []}
  end

  def query(query_text, limit) do
    conf = config()
    url = "#{conf[:base_url]}/api/v1/query"

    request_body = %{
      "query_text" => query_text,
      "max_results" => limit,
      "min_relevance" => 0.6, # Default confidence threshold
      "agent_id" => "acn_client" # Ideally passed in from caller
    }

    case Req.post(url, json: request_body, headers: conf[:headers]) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        # Normalize results to a simple list of maps for the Agent
        normalized = Enum.map(results, fn r ->
          %{
            fact_text: r["fact"],
            score: r["score"],
            node_id: r["node_id"],
            metadata: r["metadata"]
          }
        end)
        {:ok, normalized}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("CMS Query Failed with Status: #{status}")
        {:error, :query_failed}

      {:error, reason} ->
        Logger.error("CMS Query Network Error: #{inspect(reason)}")
        {:error, :network_failure}
    end
  end

  @doc """
  Checks connectivity to the remote CMS.
  Replaces the old 'init_collection' logic since the CMS manages its own state.
  """
  def check_connection do
    conf = config()
    # Using the embedder health check as a proxy for system health
    url = "#{conf[:base_url]}/api/v1/health/embedder"

    case Req.get(url, headers: conf[:headers]) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.info("Remote CMS is Online and Healthy.")
        :ok
      _ ->
        Logger.warning("Remote CMS is Unreachable or Unhealthy.")
        {:error, :cms_offline}
    end
  end
end