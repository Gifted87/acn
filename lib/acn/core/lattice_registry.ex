defmodule ACN.Core.LatticeRegistry do
  @moduledoc """
  The Lattice Registry (The Live Map).
  
  Unlike a standard registry that maps names to PIDs, the Lattice mapping is semantic and path-aware:
  Feature Description <-> File Path <-> Module Name <-> PID
  
  It enables "Horizontal Incorporation" (Discovery) so nodes can find each other without imports.
  Uses ACMS (Associative Cognitive Memory System) as the General Memory backend.
  """
  
  use GenServer
  require Logger
  
  # Mnesia table name
  @table :acn_lattice_registry
  # ACMS HTTP endpoint
  @acms_base_url "http://localhost:4000/api/v1"
  
  defstruct [:path, :module, :exports, :pid, :metadata, :acms_node_id]

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end
  
  @doc """
  Registers a capability (Leaf Node).
  Commits to both Mnesia (fast local lookup) and ACMS (semantic search).
  """
  def register(path, module, exports, pid \\ nil, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register, path, module, exports, pid, metadata})
  end

  @doc """
  Finds a capability by exact path.
  """
  def lookup_by_path(path) do
    case :mnesia.dirty_read(@table, path) do
      [{_tbl, _path, module, exports, pid, meta, _acms_id}] ->
        {:ok, %__MODULE__{path: path, module: module, exports: exports, pid: pid, metadata: meta}}
      [] -> 
        {:error, :not_found}
    end
  end
  
  @doc """
  Finds a capability by module name.
  """
  def lookup_by_module(module) do
    match_spec = [{
      { :_, :"$1", :"$2", :_, :_, :_, :_ },
      [{:==, :"$2", module}],
      [:"$_"]
    }]
    
    case :mnesia.dirty_select(@table, match_spec) do
      [{_tbl, path, _mod, exports, pid, meta, _acms_id}] ->
        {:ok, %__MODULE__{path: path, module: module, exports: exports, pid: pid, metadata: meta}}
      [] -> 
        {:error, :not_found}
    end
  end

  @doc """
  Semantic Search using ACMS.
  Returns list of candidates matching the query.
  """
  def search(query_text) do
    body = Jason.encode!(%{
      query_text: query_text,
      agent_id: "root",
      max_results: 20,
      min_relevance: 0.5,
      embedding_model: "all-MiniLM-L6-v2",
      reasoning_mode: "normal",
      system_mode: "normal"
    })
    
    headers = [{"Content-Type", "application/json"}]
    
    case HTTPoison.post("#{@acms_base_url}/query", body, headers) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"results" => results}} ->
            capabilities = Enum.map(results, fn r ->
              %{
                path: r["metadata"]["path"],
                module: r["metadata"]["module"],
                score: r["score"],
                fact: r["fact"]
              }
            end)
            {:ok, capabilities}
          _ -> {:error, :decode_failed}
        end
      {:error, reason} ->
        Logger.warn("ACMS query failed: #{inspect reason}")
        {:ok, []}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    Logger.info("Starting Lattice Registry with ACMS backend...")
    init_mnesia()
    {:ok, %{}}
  end
  
  @impl true
  def handle_call({:register, path, module, exports, pid, metadata}, _from, state) do
    # 1. Register in Mnesia (fast local lookup)
    transaction = fn ->
      # Initial write with nil acms_id, will update after ACMS responds
      :mnesia.write({@table, path, module, exports, pid, metadata, nil})
    end
    
    case :mnesia.transaction(transaction) do
      {:atomic, :ok} -> 
        Logger.info("Registered Capability: #{inspect module} at #{path}")
        
        # 2. Register in ACMS (semantic memory)
        spawn(fn -> register_to_acms(path, module, exports, metadata) end)
        
        {:reply, :ok, state}
      {:aborted, reason} -> 
        Logger.error("Failed to register capability: #{inspect reason}")
        {:reply, {:error, reason}, state}
    end
  end

  defp register_to_acms(path, module, exports, metadata) do
    fact_text = "Module #{inspect module} at #{path} with exports: #{inspect exports}"
    
    body = Jason.encode!(%{
      fact_text: fact_text,
      agent_id: "root",
      acls: %{
        read: ["public", "root", "system"],
        write: ["root", "system"]
      },
      provenance: %{source: "lattice_registry", trust_score: 1.0},
      description_payloads: [
        %{type: "object", object_type: "module_registration", data: %{
          path: path,
          module: to_string(module),
          exports: exports,
          metadata: metadata
        }}
      ]
    })
    
    headers = [{"Content-Type", "application/json"}, {"x-agent-id", "root"}]
    
    case HTTPoison.post("#{@acms_base_url}/ingest", body, headers) do
      {:ok, %{status_code: 201, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"node_id" => node_id}} ->
            Logger.info("ACMS ingestion successful: #{node_id}")
            # Update Mnesia with ACMS node_id
            update_acms_id(path, node_id)
          _ -> :ok
        end
      {:error, reason} ->
        Logger.warn("ACMS ingestion failed: #{inspect reason}")
    end
  end
  
  defp update_acms_id(path, acms_id) do
    transaction = fn ->
      case :mnesia.read(@table, path) do
        [{tbl, p, mod, exp, pid, meta, _}] ->
          :mnesia.write({tbl, p, mod, exp, pid, meta, acms_id})
        [] -> :ok
      end
    end
    :mnesia.transaction(transaction)
  end

  defp init_mnesia do
    case :mnesia.create_table(@table, [
      attributes: [:path, :module, :exports, :pid, :metadata, :acms_node_id], 
      disc_copies: [node()]
    ]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("Mnesia table creation failed: #{inspect other}")
    end
  end
end
