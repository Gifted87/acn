defmodule ACNWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :acn

  socket "/dashboard", ACNWeb.DashboardSocket,
    websocket: [check_origin: false]

  plug Plug.Static,
    at: "/",
    from: :acn,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, store: :cookie, key: "_acn_key", signing_salt: "random_salt"
  plug ACNWeb.Router
end
