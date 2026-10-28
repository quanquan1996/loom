defmodule LoomWeb.DreamController do
  @moduledoc """
  Sleep (`Loom.Dream`), for the moon in the sidebar. `:scope` is a project id,
  or `home` for the sessions outside any project.
  """
  use LoomWeb, :controller

  alias Loom.Dream

  # GET /api/dreams — every scope's status.
  def index(conn, _params), do: json(conn, %{dreams: Dream.list()})

  # GET /api/dreams/:scope
  def show(conn, %{"scope" => scope}), do: reply(conn, Dream.status(scope))

  # POST /api/dreams/:scope/session — its sleep session, made if need be.
  def session(conn, %{"scope" => scope}) do
    case Dream.open(scope) do
      {:ok, id} -> json(conn, %{session: Loom.Agent.info(id)})
      error -> reply(conn, error)
    end
  end

  # POST /api/dreams/:scope/run — sleep now.
  def run(conn, %{"scope" => scope}), do: reply(conn, Dream.run(scope))

  # PATCH /api/dreams/:scope — `enabled`; `window` and `utc_offset` for all.
  def update(conn, %{"scope" => scope} = params),
    do: reply(conn, Dream.update(scope, Map.take(params, ["enabled", "window", "utc_offset"])))

  # POST /api/dreams/:scope/undo — the memory as it was before the last sleep.
  def undo(conn, %{"scope" => scope}), do: reply(conn, Dream.undo(scope))

  # GET /api/dreams/:scope/memories
  def memories(conn, %{"scope" => scope}) do
    case Dream.status(scope) do
      {:ok, _} -> json(conn, %{memories: Dream.memories(scope)})
      error -> reply(conn, error)
    end
  end

  defp reply(conn, {:ok, status}), do: json(conn, status)

  defp reply(conn, {:error, :unknown_scope}),
    do: conn |> put_status(:not_found) |> json(%{error: "no such project"})

  defp reply(conn, {:error, :sleeping}),
    do: conn |> put_status(:conflict) |> json(%{error: "it is sleeping right now"})

  defp reply(conn, {:error, :nothing_to_undo}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "no sleep to undo"})

  defp reply(conn, {:error, reason}) when is_binary(reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: reason})

  defp reply(conn, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
end
