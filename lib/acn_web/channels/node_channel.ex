defmodule ACNWeb.NodeChannel do
  use Phoenix.Channel
  require Logger

  @impl true
  def join("acn:node:" <> _node_id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("command", %{"text" => user_input}, socket) do
    # Use AI to triage the command
    vars = %{user_input: user_input}

    case ACN.Core.ProfileLoader.load("messenger_dispatcher", vars) do
      {:ok, profile} ->
        buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
        adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
        config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}

        triage_result =
          case ACN.AI.Pipeline.run(buffer, [], config) do
            {:ok, msg, _} ->
              try do
                Jason.decode!(msg.content)
              rescue
                _ -> %{"type" => "garbage"}
              end
            _ -> %{"type" => "error"}
          end

        Logger.info("Command Triage: #{inspect(triage_result)}")

        # Route based on triage
        case triage_result["type"] do
          "command" ->
            route_command(triage_result, socket)
            {:reply, {:ok, %{status: "dispatched", triage: triage_result}}, socket}

          "query" ->
            handle_query(triage_result, socket)
            {:reply, {:ok, %{status: "answered"}}, socket}

          _ ->
            {:reply, {:error, %{reason: "Invalid command"}}, socket}
        end

      {:error, reason} ->
        Logger.error("Failed to load Dispatcher profile: #{inspect(reason)}")
        {:reply, {:error, %{reason: "Internal error"}}, socket}
    end
  end

  defp route_command(%{"target" => target, "intent" => intent}, _socket) when not is_nil(target) do
    # Resolve target agent via Registry
    target_atom = String.to_atom(target)
    pid = ACN.Core.NodeRegistry.whereis_name({target_atom, nil})

    case pid do
      pid when is_pid(pid) ->
        # Send message based on intent
        message = build_message(intent)
        GenServer.cast(pid, message)
        Logger.info("Routed command '#{intent}' to #{target}")

      :undefined ->
        Logger.warning("Target agent '#{target}' not found")
    end
  end

  defp route_command(_, _), do: :ok

  defp handle_query(%{"intent" => "get_status"}, socket) do
    # Broadcast a status request
    Phoenix.PubSub.broadcast(ACN.PubSub, "internal:raw_events", {:event, {:status_request, self()}})
    push(socket, "status_update", %{message: "Status requested"})
  end

  defp handle_query(_, _), do: :ok

  defp build_message("pause_governance"), do: {:pause_governance}
  defp build_message("resume"), do: {:resume_governance}
  defp build_message("inject_pain"), do: {:pain_signal, 50}
  defp build_message(_), do: {:unknown_command}
end
