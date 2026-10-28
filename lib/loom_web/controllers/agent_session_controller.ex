defmodule LoomWeb.AgentSessionController do
  use LoomWeb, :controller

  alias Loom.Agent

  # GET /api/agents — list live agent sessions.
  def index(conn, _params) do
    json(conn, %{sessions: Enum.map(Agent.list_sessions(), &view/1)})
  end

  # POST /api/agents — start a session.
  #
  # `backend` is required: `claude_code` or `codex`. There is no default,
  # because the choice is permanent — the conversation lives in that engine's
  # own store, so switching later would mean abandoning the history. Better to
  # make the caller say which one than to quietly pick for them.
  #
  # Deliberately takes no directory. `project_id`, optional, puts the session
  # in a project, whose workspace becomes its cwd for good (`Loom.Projects`).
  # Without one a session has no root, and the model composes absolute paths
  # from the conversation. A channel only ever attaches to an existing session,
  # so creation goes through here.
  def create(conn, params) do
    case Loom.Agent.Backend.parse(params["backend"]) do
      {:ok, backend} -> create_session(conn, backend, params)
      :error -> bad_backend(conn, params["backend"])
    end
  end

  defp create_session(conn, backend, params) do
    id = Agent.new_id()
    opts = [{:backend, backend} | build_opts(params)]

    case Agent.start_session(id, opts) do
      {:ok, _pid} ->
        conn |> put_status(:created) |> json(view(Agent.info(id)))

      {:error, {:unknown_project, _}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "no such project"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp bad_backend(conn, given) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "`backend` must be \"claude_code\" or \"codex\"",
      given: given
    })
  end

  # PATCH /api/agents/:id — any of `title` (rename), `pinned` and `project_id`
  # (move into that project, or out of any with null). The first two are local
  # to loom and never pushed to the backend; a move relocates it.
  def update(conn, %{"id" => id} = params) do
    changes =
      [
        {"title", &Agent.rename(id, &1)},
        {"pinned", &Agent.pin(id, &1)},
        {"project_id", &Agent.move(id, &1)}
      ]
      |> Enum.filter(fn {key, _} -> Map.has_key?(params, key) end)

    case Enum.find_value(changes, :ok, fn {key, change} -> refused(change.(params[key])) end) do
      :ok -> json(conn, view(Agent.info(id)))
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  defp refused(:ok), do: nil
  defp refused({:error, :busy}), do: {:error, "the session is in the middle of a turn"}
  defp refused({:error, {:unknown_project, _}}), do: {:error, "no such project"}
  defp refused({:error, reason}), do: {:error, reason}

  # DELETE /api/agents/:id — stop the session *and* discard its history.
  #
  # Stopping without deleting would be a trap in a UI: the session vanishes
  # from the list, then comes back at the next boot because `Agent.Bootstrap`
  # restores everything on disk.
  def delete(conn, %{"id" => id}) do
    Agent.delete_session(id)
    send_resp(conn, :no_content, "")
  end

  defp build_opts(params) do
    []
    |> maybe_put(:title, params["title"])
    |> maybe_put(:project, params["project_id"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: [{key, val} | opts]

  defp view(info) do
    %{
      id: info.id,
      title: info.title,
      backend: info.backend,
      backend_label: info.backend_label,
      project_id: info.project_id,
      pinned: info.pinned,
      created_at: info.created_at,
      last_active_at: info.last_active_at,
      status: info.status,
      queued: info.queued,
      queue: info.queue,
      usage: info.usage,
      context_tokens: info.context_tokens,
      context_window: info.context_window,
      turns: info.turns,
      seq: info.seq
    }
  end
end
