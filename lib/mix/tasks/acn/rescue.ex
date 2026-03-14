defmodule Mix.Tasks.Acn.Rescue do
  use Mix.Task
  require Logger

  @shortdoc "Rescues (unfreezes) an ACN node and resets LiveWire stress."

  @moduledoc """
  Rescues an ACN node by sending a :rescue cast to its controller and the global live_wire.

  Usage:
      mix acn.rescue --node <node_id>

  Example:
      mix acn.rescue --node sqrt_endpoint
  """

  def run(args) do
    # Start the necessary applications
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: [node: :string])

    node_id = opts[:node] || "root"

    IO.puts("==> Rescuing ACN System...")

    # 1. Rescue LiveWire (reset global stress)
    IO.puts("    - Resetting LiveWire stress...")
    ACN.Router.route(:rescue, {:local, :live_wire}, %ACN.Router.State{node_id: "root"})

    # 2. Rescue specific Controller
    if node_id != "root" do
      IO.puts("    - Unfreezing Controller for node: #{node_id}...")
      ACN.Router.route(:rescue, {:local, :controller}, %ACN.Router.State{node_id: node_id})
    else
        IO.puts("    - Unfreezing Root Controller...")
        ACN.Router.route(:rescue, {:local, :controller}, %ACN.Router.State{node_id: "root"})
    end

    IO.puts("==> Rescue signals sent successfully.")
  end
end
