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

    # Wait for supervision tree to stabilize
    Process.sleep(2000)

    Logger.info("Supervision tree initialized.")

    # Verify critical agents are running
    verify_agent(:live_wire, "LiveWire")
    verify_agent(:messenger, "Messenger")
    verify_agent(:controller, "Controller")

    Logger.info("Phoenix Endpoint: http://localhost:4000")

    # 2. The First Spark: Spawn Root Node via NodeSupervisor
    Logger.info("Spawning Root Node...")

    node_id = "genesis_root_#{UUID.uuid4()}"

    node_args = %{
      task: node_id,
      task_description: task_description,
      task_type: :manager,
      parent_node: nil,  # Root has no parent
      genesis_flag: true,
      context: %{
        env_config: %{
          workspace_root: Application.get_env(:acn, :workspace_root, "tmp/acn_workspaces")
        }
      }
    }

    case ACN.Core.NodeSupervisor.start_child_node(node_args) do
      {:ok, child_pid} ->
        Logger.info("✓ Child Node spawned: #{inspect(child_pid)}")

        # Initialize Governance on the Controller
        # Build the payload that the Controller expects
        governance_payload = %{
          "task_assignment" => %{
            "type" => "intermediate",
            "description" => task_description
          },
          "context" => %{
            "env_config" => %{
              "workspace_root" => Application.get_env(:acn, :workspace_root, "tmp/acn_workspaces")
            },
            "node_id" => node_id
          }
        }

        # Get Controller PID and initialize governance
    controller_pid = ACN.Core.NodeRegistry.whereis_name({:controller, :controller})

        if is_pid(controller_pid) do
          GenServer.cast(controller_pid, {:initialize_governance, governance_payload})
          Logger.info("✓ Governance initialized")
        else
          Logger.warning("! Controller not found - Governance not initialized")
        end

        Logger.info("✓ Genesis complete. The organism is alive.")
        Logger.info("")
        Logger.info("Dashboard: http://localhost:4000")
        Logger.info("Node ID: #{node_id}")
        Logger.info("Press Ctrl+C to stop.")

        # 3. Telemetry: Keep the task running
        Process.sleep(:infinity)

      {:error, reason} ->
        Logger.error("✗ Failed to spawn root node: #{inspect(reason)}")
        # Add a delay and flush to ensure we see the error
        Logger.flush()
        Process.sleep(500)
        System.halt(1)
    end
  end

  defp verify_agent(name, label) do
    # Agents use {name, name} pattern now
    pid = ACN.Core.NodeRegistry.whereis_name({name, name})
    if is_pid(pid) do
      Logger.info("#{label}: Active (#{inspect(pid)})")
    else
      Logger.warning("#{label}: Not found (Check NodeRegistry)")
    end
  end
end
