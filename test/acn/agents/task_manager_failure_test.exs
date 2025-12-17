
defmodule ACN.Agents.TaskManagerFailureTest do
  use ExUnit.Case, async: false
  require Logger

  alias ACN.Agents.TaskManager

  # Mock Adapter that simulates a Timeout/Failure
  defmodule MockFailingAdapter do
    @behaviour ACN.AI.ModelBehavior

    def chat(_messages, _tools, _opts) do
      # Simulate what happens when Ollama times out
      {:error, :timeout}
    end

    def embed(_, _), do: {:error, :not_implemented}
  end

  setup do
    # Override the default adapter to use our Failing Mock
    Application.put_env(:acn, :ai, [default_adapter: MockFailingAdapter])
    
    # Ensure Mnesia is ready (TaskManager uses it for node registry, usually)
    # But TaskManager unit tests might just run in isolation.
    # Let's start the TaskManager.
    
    {:ok, pid} = TaskManager.start_link([])
    %{pid: pid}
  end

  test "TaskManager handles Slicer failure without crashing", %{pid: pid} do
    # 1. Trigger Slicer Phase
    # We send a decompose request.
    request = %{
      "task_assignment" => %{
        "description" => "Build a flux capacitor",
        "type" => "intermediate"
      },
      "context" => %{}
    }

    GenServer.cast(pid, {:decompose, request})

    # 2. Wait for async processing
    # The Slicer runs Pipeline -> Fails -> Casts {:next_phase, :failed}
    
    # Give it a moment to process
    Process.sleep(100)

    # 3. Assert Process is still alive
    assert Process.alive?(pid), "TaskManager crashed instead of handling failure!"

    # 4. Assert State is :failed
    # We can inspect state via sys.get_state or adding a handle_call :get_state
    # Assuming we don't want to modify code just for test, we can check if it accepts other messages 
    # or just use :sys.get_state
    
    state = :sys.get_state(pid)
    assert state.phase == :failed
    
    Logger.info("✅ Verified: TaskManager survived failure and entered :failed state.")
  end
end
