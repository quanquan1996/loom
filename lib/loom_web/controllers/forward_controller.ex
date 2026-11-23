defmodule LoomWeb.ForwardController do
  @moduledoc """
  Opens `LoomWeb.ForwardSocket` to a device's forwarded port. Checks the login
  token itself, as `LoomWeb.BrowserController` does: a WebSocket can't carry
  the header `RequireAuth` reads.
  """
  use LoomWeb, :controller

  def socket(conn, %{"id" => id} = params) do
    with {:ok, _login} <- Loom.Auth.verify_token(params["token"]),
         {:ok, port, channel} <- Loom.Nodes.forward(id) do
      node = Enum.find(Loom.Nodes.list(), &(&1.id == id))
      name = (node && node.name) || id

      conn
      |> WebSockAdapter.upgrade(
        LoomWeb.ForwardSocket,
        %{
          node_id: id,
          node_name: name,
          port: port,
          channel: channel,
          ip: LoomWeb.ClientAddress.of(conn),
          rtc: params["rtc"] == "1",
          # Peer to peer only where the user switched it on for this device.
          p2p: node != nil and node.p2p
        },
        # noVNC doesn't ping and a still screen sends nothing; the switch's
        # own idle clock is what ends a forgotten one.
        timeout: :timer.hours(4),
        compress: true
      )
      |> halt()
    else
      {:error, :off} -> send_resp(conn, 409, "port forwarding is off")
      {:error, :offline} -> send_resp(conn, 503, "the device is offline")
      {:error, _} -> send_resp(conn, 401, "")
    end
  end
end
