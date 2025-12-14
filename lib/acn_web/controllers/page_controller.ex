defmodule ACNWeb.PageController do
  use Phoenix.Controller, namespace: ACNWeb

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html>
    <head>
      <title>ACN Dashboard</title>
      <script>
        const socket = new WebSocket("ws://localhost:4000/dashboard");
        const channel = socket.channel("acn:node:root");

        channel.on("status_update", msg => {
          document.getElementById("status").innerText = msg;
        });

        channel.join();
      </script>
    </head>
    <body>
      <h1>ACN Nervous System</h1>
      <p>Status: <span id="status">Initializing...</span></p>
    </body>
    </html>
    """)
  end
end
