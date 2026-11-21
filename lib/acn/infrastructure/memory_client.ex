defmodule ACN.Infrastructure.MemoryClient do
  @moduledoc """
  Client for the remote Associative Cognitive Memory System (CMS).
  
  This module acts as the bridge between the ACN (Agent/Client) and the 
  CMS (Brain/Server). It communicates exclusively via the CMS REST API.
  
  It is critical for the Supervisor's 'Wisdom' phase during Node Genesis.
  """
  require Logger
  alias ACN.Core.Artifacts.DBC

  # Default configuration with safety fallbacks
  defp config do
    config = Application.get_env(:acn, :memory, [])
    base_url = config[:cms_url] || "http://localhost:4000"
    api_key = config[:cms_api_key]

    [
      base_url: base_url, 
      headers: build_headers(api_key),
      # Critical: Prevent Node Genesis from hanging if ACMS is down
      receive_timeout: 10000, 
      connect_options: [timeout: 5000]
    ]
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}, {"x-agent-id", "root"}]
  defp build_headers(_key), do: [{"content-type", "application/json"}, {"x-agent-id", "root"}]

  @doc """
  Ingests a Digital Birth Certificate (DBC) into the remote CMS.
  """
  def ingest(%DBC{} = dbc) do
    conf = config()
    url = "#{conf[:base_url]}/api/v1/ingest"

    # Map DBC to CMS Payload
    payloads = [%{"type" => "text", "content" => dbc.fact_text}]
    payloads = 
      if dbc.source_code && dbc.source_code != "" do
        payloads ++ [%{"type" => "code", "content" => dbc.source_code}]
      else
        payloads
      end
    
    request_body = %{
      "fact_text" => dbc.fact_text,
      "agent_id" => "root", 
      "description_payloads" => payloads,
      "provenance" => Map.merge(dbc.provenance_data || %{}, %{
        "verifier_id" => dbc.verifier_id,
        "artifact_hash" => dbc.artifact_hash,
        "origin_timestamp" => DateTime.to_iso8601(dbc.timestamp),
        "full_path" => dbc.full_path,
        "filename" => dbc.filename
      }),
      "acls" => %{
        "read" => ["public", "root", "system"],
        "write" => ["root", "system"]
      }
    }

    # Merge config options for timeout
    req_options = Keyword.drop(conf, [:base_url, :headers])
    
    case Req.post(url, [json: request_body, headers: conf[:headers]] ++ req_options) do
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
  Used by SupervisorAgent to fetch 'Wisdom' before Identity Determination.
  """
  def query(query_text, limit \\ 5)

  def query(query_text, _limit) when is_nil(query_text) or query_text == "" do
    Logger.warning("MemoryClient: Aborting query with empty text.")
    {:ok, []}
  end

  def query(query_text, limit) do
    # Use the Limiter to serialize and rate-limit queries
    ACN.Infrastructure.ACMSLimiter.query(query_text, limit)
  end

  @doc """
  Internal execution of the query. Should generally be called via query/2 (Limiter).
  """
  def execute_query(query_text, limit) do
    conf = config()
    url = "#{conf[:base_url]}/api/v1/query"

    request_body = %{
      "query_text" => query_text,
      "max_results" => limit,
      "min_relevance" => 0.6,
      "agent_id" => "root",
      "embedding_model" => "all-MiniLM-L6-v2",
      "reasoning_mode" => "normal",
      "system_mode" => "normal"
    }

    req_options = Keyword.drop(conf, [:base_url, :headers])

    case Req.post(url, [json: request_body, headers: conf[:headers]] ++ req_options) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        # Keep full result context while suppressing equivalent content returned
        # from separate CMS nodes. CMS provides the stable content_identity;
        # node_id remains available to callers for provenance and traceability.
        {:ok, deduplicate_results(results)}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("CMS Query Failed with Status: #{status}")
        {:error, :query_failed}

      {:error, reason} ->
        # Silent failure preferred during Genesis to allow fallback heuristics
        Logger.warning("CMS Query Network Error: #{inspect(reason)}. Proceeding without wisdom.")
        {:ok, []} 
    end
  end

  defp deduplicate_results(results) when is_list(results) do
    {kept, _seen} =
      Enum.reduce(results, {[], MapSet.new()}, fn result, {acc, seen} ->
        case result_identity(result) do
          nil -> {[result | acc], seen}
          identity ->
            if MapSet.member?(seen, identity) do
              {acc, seen}
            else
              {[result | acc], MapSet.put(seen, identity)}
            end
        end
      end)

    Enum.reverse(kept)
  end

  defp deduplicate_results(results), do: results

  defp result_identity(result) when is_map(result) do
    identity = Map.get(result, "content_identity") || Map.get(result, :content_identity)
    if is_binary(identity) and identity != "", do: {:content, identity}, else: nil
  end

  defp result_identity(_), do: nil

  @doc """
  Checks connectivity to the remote CMS.
  """
  def check_connection do
    conf = config()
    url = "#{conf[:base_url]}/api/v1/health/embedder"

    req_options = Keyword.drop(conf, [:base_url, :headers])

    case Req.get(url, [headers: conf[:headers]] ++ req_options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      _ -> {:error, :cms_offline}
    end
  end
end
