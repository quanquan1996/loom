defmodule LoomWeb.TidyController do
  @moduledoc """
  `loom-session`, which an agent runs to tidy the user's sessions (the
  `loom-tidy` skill): list, read, archive, unarchive, merge, retitle, and
  keep. Each but unarchive records that the session was tidied (`tidied_at`),
  and `list` puts the ones new since — never tidied, or active since — first. Behind
  `LoomWeb.Plugs.NodeCliAuth`, like `loom-notice`; the caller is the
  `x-loom-session` header.

  Nothing here deletes. Archiving is a mark the page reads (`Session.archive/2`);
  a merge makes a new session and archives the ones it came from.

  What may be tidied is decided here, not by the skill, and as a whitelist:
  the sidebar's Recents — no `kind`, no employee, not pinned. Employee, Dream
  and bell sessions are referenced by id elsewhere and rotate on their own;
  they are never listed and always refused, as is any kind added later. Also
  refused: a session mid-turn, the caller itself, one with an open notice in
  the bell, and a merge across projects. A retitle may be of any of them,
  mid-turn or the caller, but never of a title the user gave.
  """
  use LoomWeb, :controller

  alias Loom.Agent

  @gist 200

  # GET /api/tidy/list — `project` (an id, or "home"), `all`, `archived`,
  # `fresh` (only those new since the last tidying). Without `project` or
  # `all`, the caller's own project. New since the last tidying first.
  def list(conn, params) do
    with {:ok, caller} <- caller(conn) do
      scope =
        cond do
          params["all"] in ["1", "true"] -> :all
          params["project"] == "home" -> nil
          is_binary(params["project"]) -> params["project"]
          true -> caller.project_id
        end

      archived? = params["archived"] in ["1", "true"]
      fresh_only? = params["fresh"] in ["1", "true"]
      open = open_notices()

      sessions =
        Agent.list_sessions()
        |> Enum.filter(&tidyable?/1)
        |> Enum.filter(&(scope == :all or &1.project_id == scope))
        |> Enum.filter(&(archived?(&1) == archived?))
        |> Enum.filter(&(not fresh_only? or fresh?(&1)))
        |> Enum.sort_by(&{not fresh?(&1), -(&1.last_active_at || &1.created_at || 0)})
        |> Enum.map(&row(&1, caller.id, open))

      json(conn, %{sessions: sessions})
    else
      error -> reply(conn, error)
    end
  end

  # GET /api/tidy/read — `id`, and `full` for every reply rather than each
  # turn's last. Tool calls and thinking are left out.
  def read(conn, %{"id" => id} = params) do
    with {:ok, _caller} <- caller(conn),
         {:ok, info} <- tidyable(id) do
      json(conn, %{
        id: id,
        title: info.title,
        messages: transcript(id, params["full"] in ["1", "true"])
      })
    else
      error -> reply(conn, error)
    end
  end

  # POST /api/tidy/archive — `ids`, and `archived` (default true).
  def archive(conn, %{"ids" => ids} = params) when is_list(ids) do
    archived? = params["archived"] != false

    # Bringing one back needs only that it is the user's to tidy.
    check = fn caller ->
      if archived?,
        do: check_all(ids, caller.id, open_notices()),
        else: Enum.find_value(ids, :ok, &with({:ok, _} <- tidyable(&1), do: nil))
    end

    with {:ok, caller} <- caller(conn),
         :ok <- check.(caller) do
      Enum.each(ids, &Agent.archive(&1, archived?))
      if archived?, do: Enum.each(ids, &Agent.tidied/1)
      json(conn, %{ok: true, ids: ids})
    else
      error -> reply(conn, error)
    end
  end

  # POST /api/tidy/merge — `title`, `summary`, `ids` (two or more, one
  # project). A new session in that project, on the backend of the most recent
  # of them, begins with the summary; they are archived.
  def merge(conn, %{"ids" => ids, "title" => title, "summary" => summary})
      when is_list(ids) and is_binary(title) and is_binary(summary) do
    with {:ok, caller} <- caller(conn),
         :ok <-
           if(length(Enum.uniq(ids)) >= 2,
             do: :ok,
             else: {:error, "merge needs two sessions or more"}
           ),
         :ok <-
           if(String.trim(title) != "" and String.trim(summary) != "",
             do: :ok,
             else: {:error, "title and summary may not be empty"}
           ),
         :ok <- check_all(ids, caller.id, open_notices()),
         infos = Enum.map(ids, &Agent.info/1),
         :ok <- one_project(infos),
         {:ok, id} <- start_merged(infos, String.trim(title), summary) do
      Enum.each(ids, &Agent.archive(&1, true))
      Enum.each([id | ids], &Agent.tidied/1)
      json(conn, %{ok: true, id: id})
    else
      error -> reply(conn, error)
    end
  end

  def merge(conn, _params), do: reply(conn, {:error, "merge takes title, summary and ids"})

  # POST /api/tidy/keep — `ids`: looked at, and left as they are.
  def keep(conn, %{"ids" => ids}) when is_list(ids) do
    with {:ok, _caller} <- caller(conn),
         :ok <- Enum.find_value(ids, :ok, &with({:ok, _} <- tidyable(&1), do: nil)) do
      Enum.each(ids, &Agent.tidied/1)
      json(conn, %{ok: true, ids: ids})
    else
      error -> reply(conn, error)
    end
  end

  # POST /api/tidy/retitle — `id`, `title`.
  def retitle(conn, %{"id" => id, "title" => title}) when is_binary(title) do
    with {:ok, _caller} <- caller(conn),
         {:ok, info} <- tidyable(id),
         :ok <-
           if(title_by(info) == "user",
             do: {:error, "#{id}: the user named it; leave the title"},
             else: :ok
           ),
         :ok <- Agent.retitle(id, title) do
      Agent.tidied(id)
      json(conn, %{ok: true, id: id, title: String.trim(title)})
    else
      {:error, :empty} -> reply(conn, {:error, "the title may not be empty"})
      error -> reply(conn, error)
    end
  end

  def retitle(conn, _params), do: reply(conn, {:error, "retitle takes id and title"})

  # Who titled it. A session from before this was kept: the first line of its
  # first message, as the session makes one, was the session's; anything else
  # the user's.
  defp title_by(%{title_by: by}) when by in ["auto", "user", "tidy"], do: by
  defp title_by(%{title: nil}), do: "auto"

  defp title_by(info) do
    first = first_message(info.id, 1_000) || ""

    auto =
      first
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.slice(0, 80)

    if auto == info.title, do: "auto", else: "user"
  end

  defp start_merged(infos, title, summary) do
    latest = Enum.max_by(infos, &(&1.last_active_at || &1.created_at || 0))
    id = Agent.new_id()
    opts = [backend: latest.backend, title: title, title_by: "tidy"]
    opts = if latest.project_id, do: [{:project, latest.project_id} | opts], else: opts
    names = Enum.map_join(infos, ", ", &"\"#{&1.title}\"")

    prompt =
      "[Loom: this conversation continues #{length(infos)} earlier ones the user merged into it " <>
        "(#{names}). This is what was established in them.]\n\n" <> summary

    with {:ok, _pid} <- Agent.start_session(id, opts),
         :ok <- Agent.seed(id, summary, prompt) do
      {:ok, id}
    else
      {:error, reason} -> {:error, "could not start the merged session: #{inspect(reason)}"}
    end
  end

  # ── Which sessions ──────────────────────────────────────────────────────

  # As the page has it: archived, and not used since.
  defp archived?(info) do
    at = info[:archived_at]
    is_integer(at) and (info.last_active_at || 0) <= at
  end

  # Never tidied, or used since it was.
  defp fresh?(info) do
    at = info[:tidied_at]
    not is_integer(at) or (info.last_active_at || 0) > at
  end

  defp tidyable?(info),
    do: info.kind == nil and info[:employee_id] == nil and info.pinned != true

  defp tidyable(id) do
    case safe_info(id) do
      nil ->
        {:error, "#{id}: no such session"}

      info ->
        if tidyable?(info),
          do: {:ok, info},
          else: {:error, "#{id}: not in Recents, not for tidying"}
    end
  end

  defp check_all(ids, caller, open) do
    Enum.find_value(ids, :ok, fn id ->
      case tidyable(id) do
        {:ok, info} ->
          cond do
            id == caller -> {:error, "#{id}: the session you are in"}
            info.status in [:starting, :running] -> {:error, "#{id}: in the middle of a turn"}
            MapSet.member?(open, id) -> {:error, "#{id}: has an open notice in the bell"}
            true -> nil
          end

        error ->
          error
      end
    end)
  end

  defp one_project(infos) do
    case infos |> Enum.map(& &1.project_id) |> Enum.uniq() do
      [_] -> :ok
      _ -> {:error, "these sessions are in different projects; merge within one"}
    end
  end

  defp open_notices do
    Loom.Notices.list()
    |> Enum.filter(&(&1["status"] == "open"))
    |> MapSet.new(& &1["session"])
  end

  defp safe_info(id) do
    if Agent.exists?(id), do: Agent.info(id)
  catch
    :exit, _ -> nil
  end

  defp row(info, caller, open) do
    %{
      id: info.id,
      title: info.title,
      project_id: info.project_id,
      backend: info.backend,
      turns: Map.get(info, :turns, 0),
      kb: div(file_size(Loom.Agent.Store.events_path(info.id)), 1024),
      created_at: info.created_at,
      last_active_at: info.last_active_at,
      archived_at: info[:archived_at],
      tidied_at: info[:tidied_at],
      fresh: fresh?(info),
      status: info.status,
      first: first_message(info.id),
      title_by: title_by(info),
      you: info.id == caller,
      open_notice: MapSet.member?(open, info.id)
    }
  end

  # ── Transcript ──────────────────────────────────────────────────────────

  defp first_message(id, limit \\ @gist) do
    Agent.Store.events_path(id)
    |> File.stream!()
    |> Stream.map(&decode/1)
    |> Enum.find_value(fn
      %{"kind" => "user", "payload" => %{"text" => text}} when is_binary(text) ->
        String.slice(text, 0, limit)

      _ ->
        nil
    end)
  rescue
    _ -> nil
  end

  # The user's messages and the agent's replies, oldest first: each turn's
  # last reply, or every one with `full`.
  defp transcript(id, full?) do
    Agent.Store.events_path(id)
    |> File.stream!()
    |> Stream.map(&decode/1)
    |> Enum.reduce({[], nil}, fn
      %{"kind" => "user", "payload" => %{"text" => t}}, {acc, last} ->
        {[%{role: "user", text: t} | flush(acc, last)], nil}

      %{"kind" => "assistant_text", "payload" => %{"text" => t}}, {acc, last} when full? ->
        {[%{role: "agent", text: t} | flush(acc, last)], nil}

      %{"kind" => "assistant_text", "payload" => %{"text" => t}}, {acc, _last} ->
        {acc, t}

      %{"kind" => "turn_done"}, {acc, last} ->
        {flush(acc, last), nil}

      _, state ->
        state
    end)
    |> then(fn {acc, last} -> flush(acc, last) end)
    |> Enum.reverse()
  rescue
    _ -> []
  end

  defp flush(acc, nil), do: acc
  defp flush(acc, text), do: [%{role: "agent", text: text} | acc]

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # ── Plumbing ────────────────────────────────────────────────────────────

  defp caller(conn) do
    with [id | _] <- get_req_header(conn, "x-loom-session"),
         info when is_map(info) <- safe_info(id) do
      {:ok, info}
    else
      _ -> {:error, "run this from a Loom session: LOOM_SESSION_ID is missing or unknown"}
    end
  end

  defp reply(conn, {:error, reason}) when is_binary(reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: reason})

  defp reply(conn, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
end
