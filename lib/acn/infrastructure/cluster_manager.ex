defmodule ACN.Infrastructure.ClusterManager do
  use GenServer
  require Logger

  @registry_table :acn_node_registry_v2

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 1. Initialize Mnesia
    ensure_mnesia_started()

    # 2. Join Cluster (if configured)
    join_cluster()

    # 3. Create Tables
    create_tables()

    # 4. Wait for Tables (with graceful fallback)
    wait_for_tables()

    {:ok, %{}}
  end

  defp ensure_mnesia_started do
    # Ensure Mnesia directory exists
    mnesia_dir = Application.get_env(:mnesia, :dir, 'priv/data/mnesia')
    File.mkdir_p!(to_string(mnesia_dir))

    # Ensure Mnesia is stopped before we potentially create schema
    :mnesia.stop()

    # Create schema if it doesn't exist
    case :mnesia.create_schema([node()]) do
      :ok -> Logger.info("Mnesia: Schema created")
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, reason} -> Logger.warning("Mnesia: Schema creation failed: #{inspect(reason)}")
    end

    # Start Mnesia
    :mnesia.start()
    Logger.info("Mnesia: Started")
  end

  defp join_cluster do
    seed_nodes = Application.get_env(:acn, :cluster)[:seed_nodes] || []

    # Filter out self
    targets = Enum.filter(seed_nodes, &(&1 != node()))

    if targets != [] do
       # Try to ping
       case Enum.find(targets, &Node.connect/1) do
         nil ->
           Logger.warning("Cluster: No seed nodes reachable via Distributed Erlang.")

         target ->
           Logger.info("Cluster: Connected to seed node #{target}")
           case :mnesia.change_config(:extra_db_nodes, [target]) do
             {:ok, _} ->
               Logger.info("Cluster: Mnesia joined cluster via #{target}")
               :mnesia.add_table_copy(:schema, node(), :disc_copies)
             error ->
               Logger.error("Cluster: Failed to join Mnesia: #{inspect(error)}")
           end
       end
    end
  end

  defp create_tables do
    # Check if table already exists
    existing_tables = :mnesia.system_info(:tables)

    if @registry_table in existing_tables do
      Logger.info("Mnesia: Table #{@registry_table} already exists")
      if Application.get_env(:acn, :clean_start) do
        Logger.info("ClusterManager: Deleting table #{@registry_table} (clean_start=true)")
        :mnesia.delete_table(@registry_table)
        Process.sleep(500)
        # Create it again immediately
        create_registry_table()
      end
    else
      create_registry_table()
    end
  end

  defp create_registry_table do
    clean_start = Application.get_env(:acn, :clean_start)

    copies_opts = if clean_start do
      # RAM copies ensure no old data persists
      [ram_copies: [node()]]
    else
      [disc_copies: [node()]]
    end

    result = :mnesia.create_table(@registry_table, [
      attributes: [:id, :pid, :node_address, :role, :parent_id, :created_at, :metadata]
    ] ++ copies_opts)

    case result do
      {:atomic, :ok} -> Logger.info("Mnesia: Table #{@registry_table} created (RAM: #{clean_start})")
      {:aborted, {:already_exists, _}} -> :ok
      {:aborted, reason} -> Logger.warning("Mnesia: Table creation failed: #{inspect(reason)}")
    end
  end

  defp wait_for_tables do
    case :mnesia.wait_for_tables([@registry_table], 5_000) do
      :ok ->
        Logger.info("Mnesia: Tables ready")
        :ok
      {:timeout, tables} ->
        Logger.warning("Mnesia: Table wait timed out for #{inspect(tables)}, proceeding anyway")
        :ok
      {:error, reason} ->
        Logger.warning("Mnesia: Table wait failed: #{inspect(reason)}, proceeding anyway")
        :ok
    end
  end

  # --- Cluster Scheduling API ---

  @doc """
  Selects the least stressed node in the cluster for spawning a new process.
  Prefers local node if the stress difference is minimal (< 10%).
  """
  def select_best_target do
    # 1. Get all nodes (connected + self)
    all_nodes = [node() | Node.list()]
    
    # 2. Poll Metrics (Parallel or Sequential? Sequential is safer for now)
    metrics = 
      Enum.map(all_nodes, fn n -> 
         poll_node_metrics(n)
      end)
    
    # 3. Sort by Stress (Ascending)
    sorted = Enum.sort_by(metrics, fn {_n, stress, _mem} -> stress end)
    
    # 4. Apply Affinity Logic
    # sorted is [{node, stress, mem}, ...]
    [{best_node, best_stress, _} | _] = sorted
    
    local_metrics = Enum.find(metrics, fn {n, _, _} -> n == node() end)
    {local_node, local_stress, _} = local_metrics || {node(), 100.0, 0}
    
    # Threshold check:
    # If best_node is remote, but local_stress - best_stress < 10, stick to local.
    threshold = Application.get_env(:acn, :cluster)[:migration_threshold] || 10.0
    
    final_target = 
      if best_node != local_node and (local_stress - best_stress) < threshold do
         local_node
      else
         best_node
      end
      
    Logger.debug("ClusterManager: Target Selection. Best: #{best_node} (#{best_stress}), Local: #{local_stress}. Picked: #{final_target}")
    
    final_target
  end

  defp poll_node_metrics(n) do
     # RPC call to that node's LiveWire
     # We use a timeout to avoid hanging spawn
     try do
       case :rpc.call(n, ACN.Agents.LiveWire, :get_remote_metrics, [], 1000) do
         {:ok, _n, stress, mem} -> {n, stress, mem}
         _ -> {n, 100.0, 0} # Treat unreachable/error as max stress
       end
     catch
       _, _ -> {n, 100.0, 0}
     end
  end
end
