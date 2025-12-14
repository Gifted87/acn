defmodule ACNWeb.DashboardSocket do
  use Phoenix.Socket

  channel "acn:node:*", ACNWeb.NodeChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    # Concrete Implementation: Assign Anonymous ID
    socket = assign(socket, :user_id, UUID.uuid4())
    {:ok, socket}
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
