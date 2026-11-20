defmodule LoomWeb.BackendsController do
  @moduledoc "The agent CLIs this Loom offers (`Loom.Backends`), for Settings and the menus."
  use LoomWeb, :controller

  # GET /api/backends
  def show(conn, _params), do: json(conn, Loom.Backends.get())

  # PUT /api/backends — `enabled` (a list) and `default`.
  def update(conn, params) do
    case Loom.Backends.put(params) do
      {:ok, backends} -> json(conn, backends)
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "invalid"})
    end
  end
end
