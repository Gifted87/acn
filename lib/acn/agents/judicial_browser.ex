defmodule ACN.JudicialBrowser do
  use GenServer

  @name __MODULE__
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def execute(session_id, args) do
    GenServer.call(@name, {:execute, session_id, args}, :infinity)
  end

  def close(session_id) do
    GenServer.call(@name, {:close, session_id}, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{port: nil, pending: nil, partial_line: <<>>}}

  @impl true
  def handle_call({:execute, session_id, args}, from, state) do
    with {:ok, state} <- ensure_worker(state),
         :ok <- send_request(state.port, %{session_id: session_id, args: args}) do
      {:noreply, %{state | pending: from, partial_line: <<>>}}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, session_id}, from, %{port: port} = state) when is_port(port) do
    case send_request(port, %{session_id: session_id, args: %{action: "close"}}) do
      :ok -> {:noreply, %{state | pending: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, _session_id}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    combined = state.partial_line <> data
    case String.split(combined, "\n", parts: 2) do
      [line, rest] ->
    case Jason.decode(line) do
      {:ok, %{"ok" => true} = response} ->
        reply_pending(state.pending, {:ok, response})
        {:noreply, %{state | pending: nil, partial_line: rest}}

      {:ok, %{"ok" => false, "error" => reason}} ->
        reply_pending(state.pending, {:error, reason})
        {:noreply, %{state | pending: nil, partial_line: rest}}

      {:error, reason} ->
        reply_pending(state.pending, {:error, "Browser worker returned invalid JSON: #{inspect(reason)}"})
        {:noreply, %{state | pending: nil, partial_line: rest}}
    end
      [partial] -> {:noreply, %{state | partial_line: partial}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = "Browser worker exited with status #{status}. Run scripts/setup_judicial_browser.sh to install its runtime."
    reply_pending(state.pending, {:error, reason})
    {:noreply, %{state | port: nil, pending: nil, partial_line: <<>>}}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    reply_pending(state.pending, {:error, "Browser worker closed unexpectedly."})
    {:noreply, %{state | port: nil, pending: nil, partial_line: <<>>}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  end
  def terminate(_reason, _state), do: :ok

  defp ensure_worker(%{port: port} = state) when is_port(port), do: {:ok, state}
  defp ensure_worker(state) do
    with node when is_binary(node) <- System.find_executable("node"),
         script <- Application.app_dir(:acn, "priv/judicial_browser/worker.mjs"),
         true <- File.regular?(script) do
      port =
        Port.open({:spawn_executable, node}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: [script]
        ])

      {:ok, %{state | port: port, partial_line: <<>>}}
    else
      nil -> {:error, "Node.js is required for judicial browser actions."}
      false -> {:error, "Judicial browser worker is missing from the application priv directory."}
      error -> {:error, inspect(error)}
    end
  rescue
    error -> {:error, "Could not start browser worker: #{Exception.message(error)}"}
  end

  defp send_request(port, request) do
    if Port.command(port, Jason.encode!(request) <> "\n"), do: :ok, else: {:error, "Browser worker is not accepting requests."}
  rescue
    error -> {:error, "Could not send browser request: #{Exception.message(error)}"}
  end

  defp reply_pending(nil, _reply), do: :ok
  defp reply_pending(from, reply), do: GenServer.reply(from, reply)
end
