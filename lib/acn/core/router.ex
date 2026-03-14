defmodule ACN.Router do
  @moduledoc """
  The Router is a library composed into every agent.
  It handles Horizontal Wiring and enforces the Security Protocol.
  """
  require Logger

  defmodule SecurityProtocolError do
    defexception message: "Security Protocol Violation"
  end

  defmodule State do
    defstruct [
      agent_role: nil,          # :specialist, :controller, etc.
      node_id: "root",          # UNIQUE ID for this logical node
      local_directory: %{},     # Map of sibling PIDs: %{actuator: #PID<...>}
      uplink: nil,              # Parent Node PID
      downlinks: %{},           # Map of Child Node PIDs
      sideways_bus: nil,        # Phoenix.PubSub topic for Nervous System
      merge_slot_id: nil        # ID of the slot in parent's NodeSheet
    ]
  end

  @doc """
  Secure Dispatch Logic: The gatekeeper.
  Function: route(payload, destination, state)
  """
  def route(payload, destination, %State{} = state) do
    case destination do
      {:local, role} ->
        # 1. Lookup with dynamic refresh
        result = 
          case Map.get(state.local_directory, role) do
            pid when is_pid(pid) -> {pid, state}
            nil -> lookup_and_refresh(role, state)
          end

        case result do
          {pid, updated_state} when is_pid(pid) ->
            # 2. Security Constraint
            # The Supervisor is exempted from token validation when talking to Actuator 
            # (e.g. for lattice_merge/physical topology setup)
            if role == :actuator and state.agent_role != :supervisor do
              validate_token!(payload)
            end

            # 3. Dispatch
            sender_role = state.agent_role
            GenServer.cast(pid, {:routed_message, sender_role, payload})
            {:ok, updated_state}

          _ ->
            Logger.warning("Routing failed: Local role #{inspect(role)} not found in local_directory.")
            {:error, :not_found}
        end

      {:uplink, _} ->
        route_uplink(payload, state)

      {:downlink, child_id} ->
        route_downlink(payload, child_id, state)

      {:sideways, topic} ->
        # Phoenix.PubSub Wiring
        target_topic = 
          case topic do
            :pain_signal -> "acn:monitor:trauma"
            :internal -> "acn:node_internal:#{state.node_id}"
            _ -> "acn:sideways:#{topic}"
          end
        
        Phoenix.PubSub.broadcast(ACN.PubSub, target_topic, {:routed_sideways, state.agent_role, payload})

      {:upstream, :merge} ->
        # Wrap payload for Lattice Protocol
        merge_payload = {:lattice_merge, [slot_id: state.merge_slot_id, data: payload]}
        route_uplink(merge_payload, state)

      {:external, :acms} ->
        ACN.Infrastructure.MemoryClient.query(payload)

      {:external, :acms_ingest} ->
        ACN.Infrastructure.MemoryClient.ingest(payload)

      {:self, _} ->
        # Internal loopback for agents (e.g. Specialists morphing/debugging)
        GenServer.cast(self(), payload)

      _ ->
        Logger.error("Unknown routing destination: #{inspect(destination)}")
        {:error, :invalid_destination}
    end
  end

  defp validate_token!(payload) do
    token =
      cond do
        is_map(payload) -> Map.get(payload, :token) || Map.get(payload, "token")
        is_tuple(payload) -> try_extract_token_from_tuple(payload)
        true -> nil
      end

    if is_nil(token) do
      Logger.error("Security Protocol Violation: Missing token for :actuator. Payload: #{inspect(payload)}")
      raise SecurityProtocolError, "Secure Dispatch Failed: Missing :token in payload for :actuator"
    end
  end

  defp try_extract_token_from_tuple(tuple) do
    # Convention: If it's {:perform_action, payload}, check payload
    case tuple do
      {:perform_action, %{token: t}} -> t
      {:perform_action, %{"token" => t}} -> t
      {:orchestrate_lifecycle, %{token: t}} -> t
      {:orchestrate_lifecycle, %{"token" => t}} -> t
      {:tests_provisioned, _work_id, _code, _cmd, t} -> t
      {:lattice_merge, _slot_id, _data, t} -> t
      {:merge_artifacts, _, t} -> t
      _ -> nil
    end
  end

  @doc """
  Legacy route/2 for backward compatibility.
  """
  def route(payload, destination) when not is_struct(destination, State) do
    case destination do
      {:local, agent_name} ->
        case ACN.Core.NodeRegistry.lookup(agent_name) do
          {:ok, %{pid: pid}} when is_pid(pid) ->
            GenServer.cast(pid, payload)
          _ ->
            Logger.warning("Routing failed: Local agent #{inspect(agent_name)} not found.")
        end

      {:sideways, topic} ->
        # Legacy PubSub fallback
        Phoenix.PubSub.broadcast(ACN.PubSub, "acn:sideways:#{topic}", payload)

      _ ->
        Logger.error("Unknown routing destination.")
    end
  end

  defp route_uplink(payload, %State{uplink: pid}) when is_pid(pid) do
    GenServer.cast(pid, payload)
  end
  defp route_uplink(_, _) do
    Logger.warning("Routing failed: Uplink not available.")
  end

  defp route_downlink(payload, child_id, %State{downlinks: downlinks}) do
    case Map.get(downlinks, child_id) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, payload)
      _ ->
        Logger.warning("Routing failed: Child #{inspect(child_id)} not found.")
    end
  end

  # --- Internal Discovery Logic ---

  def discover_local_agents(node_id \\ "root") do
    roles = [:controller, :actuator, :validator, :specialist, :task_manager, :supervisor, :live_wire, :synthesizer, :messenger]
    Enum.reduce(roles, %{}, fn role, acc ->
      # Scoped ID construction: Supervisor is the node_id, others are nodeid_role
      target_id = 
        if role == :supervisor do
          node_id
        else
          "#{node_id}_#{role}"
        end

      case ACN.Core.NodeRegistry.lookup(target_id) do
        {:ok, %{pid: pid}} -> Map.put(acc, role, pid)
        _ -> acc
      end
    end)
  end

  defp lookup_and_refresh(role, %State{} = state) do
    # Try scoped lookup
    target_id = 
      if role == :supervisor do
        state.node_id
      else
        "#{state.node_id}_#{role}"
      end

    case ACN.Core.NodeRegistry.lookup(target_id) do
      {:ok, %{pid: pid}} ->
        Logger.info("Router: Dynamically discovered local agent #{inspect(role)} -> #{inspect(pid)}")
        {pid, %{state | local_directory: Map.put(state.local_directory, role, pid)}}
      other ->
        Logger.warning("Router: Dynamic discovery FAILED for #{inspect(role)} in node #{state.node_id}. Registry returned: #{inspect(other)}")
        nil
    end
  end
end
