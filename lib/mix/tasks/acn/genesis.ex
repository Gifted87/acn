defmodule Mix.Tasks.Acn.Genesis do
  use Mix.Task
  require Logger

  @shortdoc "Ignites the ACN organism (The Big Bang)"

  @moduledoc """
  Starts the ACN system and spawns the first root node.

  ## Usage

      mix acn.genesis --task "Build a Todo App"

  ## Options

    * `--task` - The task description for the root node (required)
  """

  @impl Mix.Task
  def run(args) do
    # Parse arguments
    {opts, _, _} = OptionParser.parse(args, strict: [task: :string])

    task_description = opts[:task] || raise "Missing required --task argument"

    Logger.info("=== ACN GENESIS ===")
    Logger.info("Task: #{task_description}")

    # 1. Start the application (starts NodeSupervisor, LiveWire, Messenger)
    Mix.Task.run("app.start")

    # Wait for infrastructure to stabilize
    Process.sleep(1000)
    Logger.info("Core infrastructure initialized.")

    # 2. The First Spark: Spawn Root Node via NodeSupervisor
    Logger.info("Spawning Root Node...")
 
    # Use consistent 'root' ID for the primary node
    node_id = "root"

    workspace_root = ACN.Infrastructure.Workspace.root_path()
    # Ensure the workspace root exists, but let the identity bot choose the subfolder
    File.mkdir_p!(workspace_root)
    
    # SPECIFICATION FIDELITY: Detect if task description is actually a detailed specification
    # If it's >200 words, treat it as the original specification for 1:1 fidelity
    word_count = task_description |> String.split(~r/\s+/) |> length()
    
    {original_spec, spec_metadata, effective_task_desc} = if word_count > 200 do
      Logger.info("📋 Detected detailed specification (#{word_count} words) - enabling specification fidelity mode")
      
      # Extract a concise task summary for Pillar V
      [first_line | _] = String.split(task_description, "\n")
      summary = "Implement System defined in Specification: #{String.slice(first_line, 0, 100)}... (See Pillar VII)"
      
      {
        task_description,
        %{
          version: "1.0",
          ingested_at: DateTime.utc_now(),
          source: "genesis_command",
          word_count: word_count
        },
        summary
      }
    else
      Logger.info("🎯 Standard task description (#{word_count} words) - using normal mode")
      {nil, nil, task_description}
    end
 
    node_args = %{
      task: node_id,
      task_description: effective_task_desc,
      parent_node: nil,  # Root has no parent
      genesis_flag: true,
      path: "root",   # Signal to Supervisor to use workspace_root and let Bot extend it
      context: %{
        env_config: %{
          workspace_root: workspace_root
        }
      },
      # SPECIFICATION FIDELITY: Add specification fields for root node
      original_specification: original_spec,
      specification_depth: 0,  # Root is always depth 0
      specification_metadata: spec_metadata
    }

    case ACN.Core.NodeSupervisor.start_child_node(node_args) do
      {:ok, child_pid} ->
        Logger.info("✓ Child Node spawned: #{inspect(child_pid)}")

        # Wait for the Root Enclave to boot its children
        Process.sleep(2000)

        # Initialize Governance on the Controller
        # Get Controller PID using SCOPED name
        controller_id = "#{node_id}_controller"
        controller_pid = ACN.Core.NodeRegistry.whereis_name({:controller, controller_id})
 
        if is_pid(controller_pid) do
          Logger.info("✓ Governance initialized for #{node_id} (Controller: #{inspect(controller_pid)})")
        else
          Logger.warning("! Controller (#{controller_id}) not found - Governance may fail initialization.")
        end

        # Verify other local agents
        verify_node_agents(node_id)

        # Initialize the Root Supervisor Node
        GenServer.cast(child_pid, {:init_node, node_args})
        Logger.info("✓ Root Node initialized")

        Logger.info("✓ Genesis complete. The organism is alive.")
        Logger.info("")
        Logger.info("Dashboard: http://localhost:4000")
        Logger.info("Node ID: #{node_id}")
        Logger.info("Press Ctrl+C to stop.")

        # 3. Telemetry: Keep the task running until Root Node exits
        ref = Process.monitor(child_pid)
        receive do
          {:DOWN, ^ref, :process, _object, reason} ->
            Logger.info("Root Node exited: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("✗ Failed to spawn root node: #{inspect(reason)}")
        # Add a delay and flush to ensure we see the error
        Logger.flush()
        Process.sleep(500)
        System.halt(1)
    end
  end

  defp verify_node_agents(node_id) do
    roles = [:live_wire, :messenger, :task_manager, :actuator]
    Enum.each(roles, fn role ->
      id = "#{node_id}_#{role}"
      pid = ACN.Core.NodeRegistry.whereis_name({role, id})
      if is_pid(pid) do
        Logger.info("#{role}: Active (#{inspect(pid)})")
      else
        Logger.warning("#{role} (#{id}): Not found in NodeRegistry")
      end
    end)
  end
end
