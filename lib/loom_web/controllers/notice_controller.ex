defmodule LoomWeb.NoticeController do
  @moduledoc """
  The bell (`Loom.Notices`), two ways in.

  For the page: the list, and the user opening, approving, rejecting or
  dismissing one.

  For the `loom-notice` command an agent runs (behind `LoomWeb.Plugs.NodeCliAuth`,
  like `loom-node`): post, withdraw, and list its own. Who is posting comes from
  the `x-loom-session` header, the `LOOM_SESSION_ID` Loom gives every session
  it starts; a session belonging to a virtual employee posts as that employee,
  a sleep session as Dream, any other as itself.
  """
  use LoomWeb, :controller

  alias Loom.Notices

  # GET /api/notices
  def index(conn, _params), do: json(conn, %{notices: Notices.list()})

  # POST /api/notices/:id/read
  def read(conn, %{"id" => id}), do: reply(conn, Notices.read(id))

  # POST /api/notices/:id/answer — `approve`: true or false.
  def answer(conn, %{"id" => id} = params),
    do: reply(conn, Notices.answer(id, params["approve"] == true))

  # POST /api/notices/:id/dismiss
  def dismiss(conn, %{"id" => id}), do: reply(conn, Notices.dismiss(id))

  # ── loom-notice ─────────────────────────────────────────────────────────

  # POST /api/notice/post — `summary`, `priority`, and optionally `key`, `needs`.
  def post(conn, params) do
    with {:ok, session, source} <- source(conn) do
      attrs =
        params |> Map.take(["summary", "priority", "key", "needs"]) |> Map.put("session", session)

      reply(conn, Notices.post(source, attrs))
    else
      error -> reply(conn, error)
    end
  end

  # POST /api/notice/withdraw — `key`.
  def withdraw(conn, params) do
    with {:ok, _session, source} <- source(conn),
         :ok <- Notices.withdraw(source.id, params["key"]) do
      json(conn, %{ok: true})
    else
      error -> reply(conn, error)
    end
  end

  # GET /api/notice/mine
  def mine(conn, _params) do
    case source(conn) do
      {:ok, _session, source} -> json(conn, %{notices: Notices.open_of(source.id)})
      error -> reply(conn, error)
    end
  end

  defp source(conn) do
    with [session | _] <- get_req_header(conn, "x-loom-session"),
         {:ok, meta} <- Loom.Agent.Store.read_meta(session) do
      {:ok, session, source_of(session, meta)}
    else
      _ -> {:error, "run this from a Loom session: LOOM_SESSION_ID is missing or unknown"}
    end
  end

  defp source_of(_session, %{employee_id: id}) when is_binary(id) do
    name =
      case Loom.Employees.get(id) do
        {:ok, e} -> e["name"]
        _ -> id
      end

    %{kind: "employee", id: id, name: name}
  end

  defp source_of(_session, %{kind: "dream"} = meta) do
    scope = meta[:project_id] || "home"

    name =
      with id when is_binary(id) <- meta[:project_id],
           {:ok, project} <- Loom.Projects.get(id) do
        "Dream · " <> project.name
      else
        _ -> "Dream"
      end

    %{kind: "dream", id: "dream:" <> scope, name: name}
  end

  defp source_of(session, meta),
    do: %{kind: "session", id: session, name: meta[:title] || "A session"}

  defp reply(conn, {:ok, notice}), do: json(conn, %{notice: notice})

  defp reply(conn, {:error, :not_found}),
    do: conn |> put_status(:not_found) |> json(%{error: "no such notice"})

  defp reply(conn, {:error, reason}) when is_binary(reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: reason})

  defp reply(conn, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
end
