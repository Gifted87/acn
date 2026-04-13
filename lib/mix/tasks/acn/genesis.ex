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

    Mix.shell().info("=== ACN GENESIS ===")
    Mix.shell().info("Task: #{task_description}")

    # 1. Start the application (starts NodeSupervisor, LiveWire, Messenger)
    Mix.Task.run("app.start")

    # Wait for infrastructure to stabilize
    Process.sleep(1000)
    Mix.shell().info("Core infrastructure initialized.")

    # 2. The First Spark: Spawn Root Node via NodeSupervisor
    Mix.shell().info("Spawning Root Node...")
 
    # Use consistent 'root' ID for the primary node
    node_id = "root"

    workspace_root = ACN.Infrastructure.Workspace.root_path()
    # Ensure the workspace root exists, but let the identity bot choose the subfolder
    File.mkdir_p!(workspace_root)
    
    # SPECIFICATION FIDELITY: Always treat the task description as the original specification for 1:1 fidelity
    word_count = task_description |> String.split(~r/\s+/) |> length()
    
    {original_spec, spec_metadata, effective_task_desc} = if word_count >= 0 do
      Mix.shell().info("📋 Applying specification fidelity mode for all tasks (#{word_count} words)")
      
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
      Mix.shell().info("🎯 Standard task description (#{word_count} words) - using normal mode")
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
        Mix.shell().info("✓ Child Node spawned: #{inspect(child_pid)}")

        # Wait for the Root Enclave to boot its children
        Process.sleep(2000)

        # Initialize Governance on the Controller
        # Get Controller PID using SCOPED name
        controller_id = "#{node_id}_controller"
        controller_pid = ACN.Core.NodeRegistry.whereis_name({:controller, controller_id})
 
        if is_pid(controller_pid) do
          Mix.shell().info("✓ Governance initialized for #{node_id} (Controller: #{inspect(controller_pid)})")
        else
          Mix.shell().error("! Controller (#{controller_id}) not found - Governance may fail initialization.")
        end

        # Verify other local agents
        verify_node_agents(node_id)

        # Initialize the Root Supervisor Node
        GenServer.cast(child_pid, {:init_node, node_args})
        Mix.shell().info("✓ Root Node initialized")

        Mix.shell().info("✓ Genesis complete. The organism is alive.")
        Mix.shell().info("")
        Mix.shell().info("Dashboard: http://172.20.68.58:5051")
        Mix.shell().info("Node ID: #{node_id}")
        Mix.shell().info("Press Ctrl+C to stop.")

        # 3. Keep the task running until the Root Node finishes or exits.
        # FIX: The root supervisor intentionally stays alive after task completion,
        # so a bare :DOWN monitor never fires. Subscribe to the PubSub global topic
        # so {:genesis_complete, ^node_id} unblocks us when the task truly finishes.
        Phoenix.PubSub.subscribe(ACN.PubSub, "acn:monitor:global")
        ref = Process.monitor(child_pid)

        wait_for_completion(node_id, ref)

      {:error, reason} ->
        Logger.error("✗ Failed to spawn root node: #{inspect(reason)}")
        # Add a delay and flush to ensure we see the error
        Logger.flush()
        Process.sleep(500)
        System.halt(1)
    end
  end

  defp wait_for_completion(node_id, ref) do
    receive do
      {:genesis_complete, ^node_id, working_path} ->
        Mix.shell().info("✓ Task complete. Root organism '#{node_id}' finished successfully.")
        Mix.shell().info("Codebase: #{working_path}")
        # Explicitly exit the task after printing
        System.stop(0)

      {:genesis_complete, other_id, _path} ->
        Mix.shell().info("Received genesis_complete for '#{other_id}' (expected '#{node_id}'). Continuing to wait...")
        wait_for_completion(node_id, ref)

      {:DOWN, ^ref, :process, _object, reason} ->
        Mix.shell().info("Root Node process exited: #{inspect(reason)}")
        System.stop(0)
    end
  end

  defp verify_node_agents(node_id) do
    roles = [:live_wire, :messenger, :task_manager, :actuator]
    Enum.each(roles, fn role ->
      id = "#{node_id}_#{role}"
      pid = ACN.Core.NodeRegistry.whereis_name({role, id})
      if is_pid(pid) do
        Mix.shell().info("#{role}: Active (#{inspect(pid)})")
      else
        Mix.shell().error("#{role} (#{id}): Not found in NodeRegistry")
      end
    end)
  end
end
