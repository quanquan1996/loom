defmodule LoomWeb.AgentDraftController do
  @moduledoc "A session's unsent composer text; see `Loom.Agent.Draft`."
  use LoomWeb, :controller

  alias Loom.Agent
  alias Loom.Agent.Draft

  # GET /api/agents/:id/draft
  def show(conn, %{"id" => id}) do
    # Also what keeps the id from being a path: an unknown one has no process.
    if Agent.exists?(id),
      do: json(conn, Draft.read(id)),
      else: conn |> put_status(:not_found) |> json(%{error: "unknown session"})
  end

  # PUT /api/agents/:id/draft — `text`, the whole draft; "" clears it.
  def update(conn, %{"id" => id} = params) do
    cond do
      not Agent.exists?(id) ->
        conn |> put_status(:not_found) |> json(%{error: "unknown session"})

      not is_binary(params["text"]) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "`text` must be a string"})

      byte_size(params["text"]) > Draft.limit() ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "draft too long"})

      true ->
        json(conn, Draft.write(id, params["text"]))
    end
  end
end
