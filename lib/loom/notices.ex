defmodule Loom.Notices do
  @moduledoc """
  The bell: what the agents working for the user want them to see, each with a
  priority from 0 (most urgent) to 10, so a day's worth of reports can be gone
  through in order rather than all at once.

  - **Who posts.** Virtual employees, through their work card's `report`
    (`Loom.Employees`); any other session through the `loom-notice` command
    (`LoomWeb.NoticeController`), which knows the session from
    `LOOM_SESSION_ID`. How to pick a priority, and when to raise, lower or
    withdraw one, is the agents' judgement, written down in the `loom-notify`
    skill; what is here is only what must not be left to them.
  - **Three bands.** 0–2 urgent: a notification at once. 3–5 important: one
    notification at 20:00 for all of them. 6–10 the rest: no notification.
    Between 22:00 and 07:00 only 0–1 notify; a 2 waits for 07:00.
  - **One urgent a day per source.** A second one the same day is posted as a
    3, with a note saying why: the agents decide how urgent things are, but
    one that cries wolf cannot keep waking the user.
  - **A key per source** makes a notice something to update rather than
    repeat: posting the same key again replaces the open one.
  - **Done** is the user's: answering in its session (any message they type
    there), approving or rejecting it in the bell, or, for one that only asks
    to be read, opening it. The source may withdraw it. 6–10 expire after a
    week unread; anything settled is kept for 30 days.

  **To-dos** live here too: the user's own list, beside the bell. The user
  adds to it, or tells an agent to (`loom-notice todo`): a soft rule, kept by
  the `loom-notify` skill, not by this code.

  **The bell's chat** is a hidden Claude Code session (`kind: "bell"`), made
  on first use, whose standing orders (`Loom.Notices.Prompt`) are to go
  through the notices and to-dos with the user in plain words. Only it may
  act on notices for the user through `loom-notice` (answer, reply, done).

  Truth is `~/.loom/notices.json`. The whole lists go to every client on the
  lobby topic as `{:notices, list}` and `{:todos, list}` whenever they change.
  """
  use GenServer

  require Logger

  alias Loom.Agent

  @name __MODULE__
  @tick :timer.minutes(1)
  # The user's wall clock, as for employees and sleep: Asia/Shanghai.
  @offset 480
  @digest_hour 20
  @quiet {22, 7}
  @fyi_ttl :timer.hours(24 * 7)
  @kept :timer.hours(24 * 30)
  @needs ~w(read reply approve)
  @summary_max 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  # ── API ─────────────────────────────────────────────────────────────────

  @doc "Every notice still kept, newest first, as the bell shows them."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc """
  Post, or update by `key`: `source` is `%{kind:, id:, name:}`; `attrs` has
  `summary` and `priority`, and may have `key`, `needs` (`read`, `reply` or
  `approve`; `read` by default) and `session`, the session it points to.
  """
  def post(source, attrs, server \\ @name), do: GenServer.call(server, {:post, source, attrs})

  @doc "The source takes back its open notice with `key`."
  def withdraw(source_id, key, server \\ @name),
    do: GenServer.call(server, {:withdraw, source_id, key})

  @doc "A source's open notices, for it to look over."
  def open_of(source_id, server \\ @name), do: GenServer.call(server, {:open_of, source_id})

  @doc "The user opened it: done if it only asked to be read."
  def read(id, server \\ @name), do: GenServer.call(server, {:read, id})

  @doc "The user approved (`true`) or rejected it in the bell; told to its session."
  def answer(id, approve?, server \\ @name), do: GenServer.call(server, {:answer, id, approve?})

  @doc "The user answered it in the bell: `text` goes to its session as theirs."
  def reply(id, text, server \\ @name), do: GenServer.call(server, {:reply, id, text})

  @doc "Settled by hand, without an answer."
  def dismiss(id, server \\ @name), do: GenServer.call(server, {:dismiss, id})

  @doc "The user's to-dos: open first (by due date), then the done ones."
  def todos(server \\ @name), do: GenServer.call(server, :todos)

  @doc "A to-do: `text`, and optionally `due` (`YYYY-MM-DD`) and `session`; `by` who added it."
  def add_todo(attrs, by, server \\ @name), do: GenServer.call(server, {:add_todo, attrs, by})

  @doc "Change one: `done`, `text`, `due`."
  def update_todo(id, attrs, server \\ @name),
    do: GenServer.call(server, {:update_todo, id, attrs})

  def delete_todo(id, server \\ @name), do: GenServer.call(server, {:delete_todo, id})

  @doc "The bell's chat session, made on first use."
  def session(server \\ @name), do: GenServer.call(server, :session, 30_000)

  @doc "The user wrote in `session_id`: what was open there is answered."
  def replied(session_id, server \\ @name), do: GenServer.cast(server, {:replied, session_id})

  @doc "A session is gone, or a source let go: its open notices go with it."
  def forget_session(session_id, server \\ @name),
    do: GenServer.cast(server, {:forget_session, session_id})

  def path, do: Application.get_env(:loom, __MODULE__, [])[:path] || default_path()
  defp default_path, do: Path.join(Agent.Store.home(), "notices.json")

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    tick = Keyword.get(opts, :tick) || Application.get_env(:loom, __MODULE__, [])[:tick] || @tick
    {notices, marks, todos} = load(path)

    state = %{
      path: path,
      tick: tick,
      notices: notices,
      # The days the 20:00 digest and the 07:00 catch-up last went out.
      marks: marks,
      todos: todos,
      clock: Keyword.get(opts, :clock, &now/0),
      notify: Keyword.get(opts, :notify, &Loom.Push.notify/3),
      submit: Keyword.get(opts, :submit, &submit/2)
    }

    Process.send_after(self(), :tick, tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, views(state), state}

  def handle_call(:todos, _from, state), do: {:reply, todo_views(state), state}

  def handle_call({:add_todo, attrs, by}, _from, state) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    text = attrs["text"] |> to_string() |> String.trim()

    cond do
      text == "" ->
        {:reply, {:error, "a to-do needs its text"}, state}

      not due?(attrs["due"]) ->
        {:reply, {:error, "due is a date, YYYY-MM-DD"}, state}

      true ->
        now = state.clock.()

        t = %{
          "id" => "t_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)),
          "text" => text,
          "due" => blank_to_nil(attrs["due"]),
          "session" => blank_to_nil(attrs["session"]),
          "by" => by,
          "done" => false,
          "created_at" => now
        }

        state = put_in(state.todos[t["id"]], t)
        {:reply, {:ok, t}, changed(state)}
    end
  end

  def handle_call({:update_todo, id, attrs}, _from, state) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    cond do
      state.todos[id] == nil -> {:reply, {:error, :not_found}, state}
      not due?(attrs["due"]) -> {:reply, {:error, "due is a date, YYYY-MM-DD"}, state}
      true -> do_update_todo(state, id, attrs)
    end
  end

  def handle_call({:delete_todo, id}, _from, state) do
    case state.todos[id] do
      nil -> {:reply, {:error, :not_found}, state}
      _ -> {:reply, :ok, changed(update_in(state.todos, &Map.delete(&1, id)))}
    end
  end

  def handle_call(:session, _from, state) do
    id = state.marks["session"]

    result =
      cond do
        is_binary(id) and Agent.exists?(id) ->
          {:ok, id}

        is_binary(id) and match?({:ok, _}, Agent.Store.read_meta(id)) ->
          with {:ok, _} <- Agent.restore_session(id), do: {:ok, id}

        true ->
          id = Agent.new_id()

          with {:ok, _} <-
                 Agent.start_session(id, backend: :claude_code, kind: "bell", title: "Bell"),
               do: {:ok, id}
      end

    case result do
      {:ok, id} -> {:reply, {:ok, id}, changed(put_in(state.marks["session"], id))}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:post, source, attrs}, _from, state) do
    case validate(source, attrs) do
      {:ok, source, attrs} ->
        {n, state} = upsert(state, source, attrs)
        {:reply, {:ok, view(n)}, changed(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:withdraw, source_id, key}, _from, state) do
    case find_open(state, source_id, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      n ->
        state = settle(state, n, "withdrawn", "Withdrawn by #{n["source"]["name"]}")
        {:reply, :ok, changed(state)}
    end
  end

  def handle_call({:open_of, source_id}, _from, state) do
    open =
      state.notices
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "open" and &1["source"]["id"] == source_id))
      |> Enum.sort_by(&{&1["priority"], -&1["created_at"]})
      |> Enum.map(&view/1)

    {:reply, open, state}
  end

  def handle_call({:read, id}, _from, state) do
    case state.notices[id] do
      %{"status" => "open", "needs" => "read"} = n ->
        state = settle(state, n, "done", "Read")
        {:reply, {:ok, view(state.notices[id])}, changed(state)}

      nil ->
        {:reply, {:error, :not_found}, state}

      n ->
        {:reply, {:ok, view(n)}, state}
    end
  end

  def handle_call({:answer, id, approve?}, _from, state) do
    case state.notices[id] do
      %{"status" => "open"} = n ->
        word = if approve?, do: "Approved", else: "Rejected"

        if n["session"] do
          mark = if approve?, do: "✅", else: "❌"
          state.submit.(n["session"], "#{mark} #{word}: #{n["summary"]}")
        end

        n = Map.put(n, "answer", if(approve?, do: "approve", else: "reject"))
        state = settle(put_in(state.notices[id], n), n, "done", "#{word} in the bell")
        {:reply, {:ok, view(state.notices[id])}, changed(state)}

      nil ->
        {:reply, {:error, :not_found}, state}

      n ->
        {:reply, {:ok, view(n)}, state}
    end
  end

  def handle_call({:reply, id, text}, _from, state) do
    text = String.trim(to_string(text))

    case state.notices[id] do
      _ when text == "" ->
        {:reply, {:error, "an empty reply"}, state}

      %{"status" => "open", "session" => session} = n when is_binary(session) ->
        state.submit.(session, text)
        n = Map.put(n, "answer", text)
        state = settle(put_in(state.notices[id], n), n, "done", "Answered in the bell")
        {:reply, {:ok, view(state.notices[id])}, changed(state)}

      nil ->
        {:reply, {:error, :not_found}, state}

      n ->
        {:reply, {:ok, view(n)}, state}
    end
  end

  def handle_call({:dismiss, id}, _from, state) do
    case state.notices[id] do
      %{"status" => "open"} = n ->
        state = settle(state, n, "done", "Dismissed")
        {:reply, {:ok, view(state.notices[id])}, changed(state)}

      nil ->
        {:reply, {:error, :not_found}, state}

      n ->
        {:reply, {:ok, view(n)}, state}
    end
  end

  @impl true
  def handle_cast({:replied, session}, state) do
    state =
      Enum.reduce(open_in(state, session), state, &settle(&2, &1, "done", "Answered in chat"))

    {:noreply, changed(state)}
  end

  def handle_cast({:forget_session, session}, state) do
    state =
      Enum.reduce(
        open_in(state, session),
        state,
        &settle(&2, &1, "withdrawn", "Its session is gone")
      )

    {:noreply, changed(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick)
    {:noreply, state |> expire() |> digest() |> catch_up() |> changed()}
  end

  defp do_update_todo(state, id, attrs) do
    t = state.todos[id]
    now = state.clock.()

    t =
      t
      |> then(&if(is_boolean(attrs["done"]), do: Map.put(&1, "done", attrs["done"]), else: &1))
      |> then(&if(&1["done"] and not t["done"], do: Map.put(&1, "done_at", now), else: &1))
      |> then(&if(&1["done"], do: &1, else: Map.delete(&1, "done_at")))
      |> then(fn t ->
        case attrs["text"] do
          text when is_binary(text) and text != "" -> Map.put(t, "text", String.trim(text))
          _ -> t
        end
      end)
      |> then(
        &if(Map.has_key?(attrs, "due"),
          do: Map.put(&1, "due", blank_to_nil(attrs["due"])),
          else: &1
        )
      )

    state = put_in(state.todos[id], t)
    {:reply, {:ok, t}, changed(state)}
  end

  defp due?(nil), do: true
  defp due?(""), do: true
  defp due?(d) when is_binary(d), do: match?({:ok, _}, Date.from_iso8601(d))
  defp due?(_), do: false

  # ── Posting ─────────────────────────────────────────────────────────────

  defp validate(source, attrs) do
    source = Map.new(source, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    summary = attrs["summary"] |> to_string() |> String.trim()
    priority = attrs["priority"]

    cond do
      not is_binary(source["id"]) ->
        {:error, "no source"}

      summary == "" ->
        {:error, "a notice needs a summary"}

      not (is_integer(priority) and priority in 0..10) ->
        {:error, "priority must be a whole number from 0 (most urgent) to 10"}

      attrs["needs"] not in [nil | @needs] ->
        {:error, "needs must be one of #{Enum.join(@needs, ", ")}"}

      true ->
        summary =
          if String.length(summary) > @summary_max,
            do: String.slice(summary, 0, @summary_max - 1) <> "…",
            else: summary

        {:ok, Map.put_new(source, "name", source["id"]),
         %{
           "summary" => summary,
           "priority" => priority,
           "key" => blank_to_nil(attrs["key"]),
           "needs" => attrs["needs"] || "read",
           "session" => blank_to_nil(attrs["session"])
         }}
    end
  end

  defp upsert(state, source, attrs) do
    now = state.clock.()
    old = attrs["key"] && find_open(state, source["id"], attrs["key"])
    {priority, note} = capped(state, source["id"], attrs["key"], attrs["priority"], now)

    n =
      (old ||
         %{
           "id" => "n_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)),
           "source" => source,
           "status" => "open",
           "created_at" => now
         })
      |> Map.merge(attrs)
      |> Map.merge(%{
        "source" => source,
        "asked" => attrs["priority"],
        "priority" => priority,
        "note" => note,
        "updated_at" => now,
        "held" => false
      })

    # A notification when it is new or has become more urgent than it was.
    rose? = old == nil or priority < old["priority"]
    n = if rose?, do: alert(state, n, now), else: Map.put(n, "held", old["held"] || false)
    {n, put_in(state.notices[n["id"]], n)}
  end

  # One urgent a day per source; another the same day is posted as important.
  defp capped(state, source_id, key, priority, now) when priority <= 2 do
    day = day(now)

    others =
      Enum.any?(Map.values(state.notices), fn n ->
        n["source"]["id"] == source_id and n["asked"] <= 2 and n["priority"] <= 2 and
          day(n["created_at"]) == day and (key == nil or n["key"] != key)
      end)

    if others,
      do: {3, "Lowered from #{priority}: one urgent a day per source"},
      else: {priority, nil}
  end

  defp capped(_state, _source_id, _key, priority, _now), do: {priority, nil}

  defp alert(state, n, now) do
    cond do
      n["priority"] > 2 ->
        n

      n["priority"] == 2 and quiet?(now) ->
        Map.put(n, "held", true)

      true ->
        state.notify.(title(n), n["summary"], n["session"])
        n
    end
  end

  defp title(n), do: "#{n["source"]["name"]} · #{label(n)}"

  defp label(%{"needs" => "approve"}), do: "needs your approval"
  defp label(%{"needs" => "reply"}), do: "needs you"
  defp label(_), do: "urgent"

  # ── The clock ───────────────────────────────────────────────────────────

  # Unread 6–10 go after a week; anything settled after 30 days.
  defp expire(state) do
    now = state.clock.()

    Enum.reduce(Map.values(state.notices), state, fn n, state ->
      cond do
        n["status"] == "open" and n["priority"] >= 6 and now - n["created_at"] > @fyi_ttl ->
          settle(state, n, "expired", "Expired unread after a week")

        n["status"] != "open" and now - (n["done_at"] || n["updated_at"]) > @kept ->
          update_in(state.notices, &Map.delete(&1, n["id"]))

        true ->
          state
      end
    end)
    |> then(fn state ->
      # Done to-dos are kept as long as settled notices.
      todos =
        Map.reject(state.todos, fn {_, t} -> t["done"] and now - (t["done_at"] || 0) > @kept end)

      %{state | todos: todos}
    end)
  end

  # 20:00: one notification for all the important ones still open.
  defp digest(state) do
    now = state.clock.()
    today = day(now)

    if hour(now) >= @digest_hour and state.marks["digest"] != today do
      open = state |> open() |> Enum.filter(&(&1["priority"] in 3..5))

      if open != [] do
        body = open |> Enum.map(&"#{&1["source"]["name"]}: #{&1["summary"]}") |> Enum.join(" · ")
        state.notify.("#{length(open)} important #{plural(length(open))} waiting", body, nil)
      end

      put_in(state.marks["digest"], today)
    else
      state
    end
  end

  # 07:00: the urgent ones that came in during the night.
  defp catch_up(state) do
    now = state.clock.()
    today = day(now)

    if not quiet?(now) and state.marks["morning"] != today do
      held = state |> open() |> Enum.filter(& &1["held"])

      case held do
        [] ->
          :ok

        [n] ->
          state.notify.(title(n), n["summary"], n["session"])

        list ->
          state.notify.(
            "#{length(list)} urgent overnight",
            Enum.map_join(list, " · ", & &1["summary"]),
            nil
          )
      end

      state = Enum.reduce(held, state, fn n, s -> put_in(s.notices[n["id"]]["held"], false) end)
      put_in(state.marks["morning"], today)
    else
      state
    end
  end

  defp quiet?(now) do
    {from, to} = @quiet
    h = hour(now)
    h >= from or h < to
  end

  defp local(ms), do: DateTime.from_unix!(div(ms, 1000) + @offset * 60)
  defp hour(ms), do: local(ms).hour
  defp day(ms), do: ms |> local() |> DateTime.to_date() |> Date.to_iso8601()

  defp plural(1), do: "thing"
  defp plural(_), do: "things"

  # ── State ───────────────────────────────────────────────────────────────

  defp open(state), do: state.notices |> Map.values() |> Enum.filter(&(&1["status"] == "open"))

  defp open_in(state, session),
    do: state |> open() |> Enum.filter(&(&1["session"] == session))

  defp find_open(state, source_id, key) do
    state
    |> open()
    |> Enum.find(&(&1["source"]["id"] == source_id and &1["key"] == key))
  end

  defp settle(state, n, status, note) do
    now = state.clock.()

    n =
      Map.merge(n, %{
        "status" => status,
        "done_at" => now,
        "updated_at" => now,
        "held" => false,
        "note" => note
      })

    put_in(state.notices[n["id"]], n)
  end

  # Saved and told to every client, if anything changed since last time.
  defp changed(state) do
    snapshot = {state.notices, state.marks, state.todos}

    case Process.get(:notices_saved) do
      ^snapshot ->
        :ok

      old ->
        Process.put(:notices_saved, snapshot)
        save(state)

        if not match?({notices, _, _} when notices == state.notices, old),
          do: Phoenix.PubSub.broadcast(Loom.PubSub, Agent.lobby_topic(), {:notices, views(state)})

        if not match?({_, _, todos} when todos == state.todos, old),
          do:
            Phoenix.PubSub.broadcast(
              Loom.PubSub,
              Agent.lobby_topic(),
              {:todos, todo_views(state)}
            )
    end

    state
  end

  defp views(state) do
    state.notices |> Map.values() |> Enum.sort_by(& &1["created_at"], :desc) |> Enum.map(&view/1)
  end

  @doc false
  def view(n), do: Map.drop(n, ["asked", "held"])

  defp todo_views(state) do
    {done, open} = state.todos |> Map.values() |> Enum.split_with(& &1["done"])
    # Open: what is due first, then the undated, newest first. Done: latest first.
    Enum.sort_by(open, &{&1["due"] || "9999", -&1["created_at"]}) ++
      Enum.sort_by(done, &(-(&1["done_at"] || 0)))
  end

  defp submit(session, text) do
    Agent.submit(session, text, origin: "notice")
  catch
    :exit, reason -> Logger.warning("Loom.Notices: cannot tell #{session}: #{inspect(reason)}")
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"notices" => list} = data} when is_list(list) <- Jason.decode(body) do
      Process.put(:notices_saved, nil)

      {Map.new(list, &{&1["id"], &1}), data["marks"] || %{},
       Map.new(data["todos"] || [], &{&1["id"], &1})}
    else
      {:error, :enoent} ->
        {%{}, %{}, %{}}

      other ->
        Logger.error("Loom.Notices cannot read #{path} (#{inspect(other)}); starting over")
        {%{}, %{}, %{}}
    end
  end

  defp save(state) do
    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    list = state.notices |> Map.values() |> Enum.sort_by(& &1["created_at"])
    todos = state.todos |> Map.values() |> Enum.sort_by(& &1["created_at"])

    File.write!(
      tmp,
      Jason.encode_to_iodata!(%{notices: list, marks: state.marks, todos: todos}, pretty: true)
    )

    File.rename!(tmp, state.path)
  end

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(_), do: nil

  defp now, do: System.system_time(:millisecond)
end
