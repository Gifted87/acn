defmodule ACN.Infrastructure.ACMSLimiter do
  @moduledoc """
  GenServer that enforces a rate limit for ACMS queries.
  Ensures no more than 1 query per second is executed system-wide.
  """
  use GenServer
  require Logger

  defmodule State do
    defstruct last_request_at: 0, queue: :queue.new(), timer: nil
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules and executes a query through the rate limiter.
  """
  def query(query_text, limit) do
    # Increased timeout to handle large backlogs, but non-blocking internal logic
    GenServer.call(__MODULE__, {:query, query_text, limit}, 600_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:query, query_text, limit}, from, state) do
    new_queue = :queue.in({from, query_text, limit}, state.queue)
    state = %{state | queue: new_queue}
    
    state = schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, state) do
    case :queue.out(state.queue) do
      {{:value, {from, query_text, limit}}, remaining_queue} ->
        # Perform the actual query in a separate task to avoid blocking the limiter
        Task.start(fn ->
          result = ACN.Infrastructure.MemoryClient.execute_query(query_text, limit)
          GenServer.reply(from, result)
        end)

        new_state = %{state | queue: remaining_queue, last_request_at: System.system_time(:millisecond), timer: nil}
        {:noreply, schedule_next(new_state)}

      {:empty, _} ->
        {:noreply, %{state | timer: nil}}
    end
  end

  defp schedule_next(%State{timer: timer} = state) when is_reference(timer), do: state
  defp schedule_next(state) do
    if :queue.is_empty(state.queue) do
      state
    else
      now = System.system_time(:millisecond)
      elapsed = now - state.last_request_at
      wait_time = max(0, 1000 - elapsed)
      
      timer = Process.send_after(self(), :process_next, wait_time)
      %{state | timer: timer}
    end
  end
end
