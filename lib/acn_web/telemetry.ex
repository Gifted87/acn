defmodule ACNWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor for ACN metrics.
  """
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # No children for now - metrics will be added later
    Supervisor.init([], strategy: :one_for_one)
  end
end
