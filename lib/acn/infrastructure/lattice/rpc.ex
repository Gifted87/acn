defmodule ACN.Infrastructure.Lattice.RPC do
  @moduledoc """
  Wraps remote calls to ensure safety and strict timeouts.
  Prevents the Lattice from deadlocking on zombie nodes.
  """
  require Logger

  @default_timeout 5_000
  @max_payload_bytes 1_000_000 # 1MB

  @doc """
  Performs a safe GenServer call to a potentially remote PID.

  Args:
  - pid: The target PID (local or remote).
  - request: The message/request to send.
  - timeout: ms (default 5000).

  Returns:
  - {:ok, result}
  - {:error, :timeout}
  - {:error, :unreachable}
  - {:error, :payload_too_large}
  """
  def fast_call(pid, request, timeout \\ @default_timeout, opts \\ []) do
    if :erlang.term_to_binary(request) |> byte_size() > @max_payload_bytes do
      Logger.error("RPC Safety: Payload too large for #{inspect(pid)}")
      {:error, :payload_too_large}
    else
      try do
        result = GenServer.call(pid, request, timeout)
        {:ok, result}
      catch
        :exit, {:timeout, _} ->
          if !opts[:silent], do: Logger.warning("RPC Timeout calling #{inspect(pid)}")
          {:error, :timeout}

        :exit, {{:nodedown, _node}, _} ->
          if !opts[:silent], do: Logger.warning("RPC Node Down calling #{inspect(pid)}")
          {:error, :unreachable}

        :exit, {reason, _} ->
          # Silence expected :noproc (process died/finished) if requested
          if !opts[:silent] or reason != :noproc do
             Logger.warning("RPC Failed calling #{inspect(pid)}: #{inspect(reason)}")
          end
          {:error, :unreachable}
      end
    end
  end
end
