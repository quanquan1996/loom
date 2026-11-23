defmodule LoomWeb.P2PController do
  @moduledoc "Settings' P2P switch (`Loom.P2P`)."
  use LoomWeb, :controller

  # GET /api/p2p
  def show(conn, _params), do: json(conn, %{on: Loom.P2P.on?()})

  # PUT /api/p2p — `on`.
  def update(conn, %{"on" => on}) when is_boolean(on) do
    :ok = Loom.P2P.put(on)
    json(conn, %{on: on})
  end

  def update(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid"})
end
