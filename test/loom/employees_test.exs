defmodule Loom.EmployeesTest do
  # Not async: sessions, the backend map and Loom's home are global.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias Loom.Employees
  alias Loom.Employees.Card

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-employees-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    previous_home = Application.get_env(:loom, :home)

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, Path.join(dir, "sessions"))
      |> Keyword.put(:workspace, Path.join(dir, "home"))
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub, kiro: BackendStub})
    )

    Application.put_env(:loom, :home, dir)
    start_supervised!({BackendStub, notify: self()})

    name = :"employees_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Employees,
       name: name, path: Path.join(dir, "employees.json"), tick: :timer.hours(24), run: true},
      id: name
    )

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)

      if previous_home,
        do: Application.put_env(:loom, :home, previous_home),
        else: Application.delete_env(:loom, :home)

      File.rm_rf(dir)
    end)

    {:ok, server: name, dir: dir}
  end

  # The session says `text` and the turn ends, as Claude Code would.
  defp end_turn(session, text, server) do
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, session)

    send(
      pid,
      {:stub, [{:event, :assistant_text, %{text: text}}, {:event, :turn_done, %{}}]}
    )

    :sys.get_state(pid)
    :sys.get_state(server)
  end

  defp card(map), do: "Done for now.\n\n```employee-card\n#{Jason.encode!(map)}\n```"

  describe "the card" do
    test "the last block is the card, and only what is shaped right is kept" do
      text = """
      Earlier: ```employee-card
      {"next": "continue"}
      ```
      Later:
      ```employee-card
      {"next": "nap", "summary": "read the docs", "sleep_minutes": 30,
       "report": {"level": "loud", "text": "x"}}
      ```
      """

      assert Card.parse(text) == %{"summary" => "read the docs", "sleep_minutes" => 30}
      assert Card.parse("no card") == %{}
      assert Card.parse("```employee-card\nnot json\n```") == %{}
    end

    test "a wall-clock time is read in the boss's time zone" do
      assert Card.local_time("2026-10-29 09:00", 480) ==
               DateTime.to_unix(~U[2026-10-29 01:00:00Z], :millisecond)

      assert Card.local_time("tomorrow", 480) == nil
    end
  end

  test "hiring makes two hidden sessions in its own workspace, with its standing orders",
       %{server: server, dir: dir} do
    {:ok, e} = Employees.create(%{"name" => "小研", "role" => "researcher"}, server)

    for {key, kind} <- [{"chat_session", "employee_chat"}, {"work_session", "employee_work"}] do
      info = Agent.info(e[key])
      assert info.kind == kind
      assert info.employee_id == e["id"]
    end

    assert e["workspace"] == Path.join([dir, "employees", e["id"], "workspace"])
    assert File.read!(Path.join(e["workspace"], ".employee/status.md")) =~ "小研"
    assert BackendStub.last_meta().instructions =~ "You are 小研, a virtual employee"
    assert BackendStub.last_meta().cc_model == "opus"
    assert e["status"] == "sleeping"
  end

  test "a wake-up is a turn of the work session; its card says what comes next",
       %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小码"}, server)
    {:ok, e} = Employees.add_kpi(e["id"], %{"title" => "Ship the parser"}, server)
    [kpi] = e["kpis"]

    {:ok, _} = Employees.wake(e["id"], "start with the tests", server)
    text = BackendStub.await_turn()
    assert text =~ "[Wake-up from Loom"
    assert text =~ "start with the tests"
    assert text =~ "Ship the parser"

    end_turn(
      e["work_session"],
      card(%{
        "next" => "sleep",
        "sleep_minutes" => 30,
        "summary" => "wrote the tests",
        "kpis" => [%{"id" => kpi["id"], "progress" => 100, "status" => "done"}],
        "report" => %{"level" => "important", "text" => "ready for review"}
      }),
      server
    )

    {:ok, e} = Employees.get(e["id"], server)
    [kpi] = e["kpis"]
    # Done is the boss's to say.
    assert kpi["status"] == "review"
    assert kpi["progress"] == 100
    assert e["attention"]["level"] == "important"
    assert [%{"summary" => "wrote the tests"}] = e["log"]
    # Thirty minutes, as asked: more than the gap, less than the heartbeat.
    assert_in_delta e["wake_at"] - System.system_time(:millisecond), 30 * 60_000, 5_000

    {:ok, e} = Employees.review_kpi(e["id"], kpi["id"], true, nil, server)
    assert [%{"status" => "done"}] = e["kpis"]

    # A later turn with nothing to report leaves the report up until it is seen.
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.await_turn()
    end_turn(e["work_session"], card(%{"summary" => "daily report"}), server)
    {:ok, e} = Employees.get(e["id"], server)
    assert e["attention"]["text"] == "ready for review"
    {:ok, e} = Employees.seen(e["id"], server)
    assert e["attention"] == nil
  end

  test "a turn's end still in the mailbox is read before waking again", %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小码"}, server)
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.await_turn()
    # Asked again mid-turn: due as soon as this turn is over.
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.refute_turn()

    # The cost lands first, and the end just after it, as a session sends them.
    :sys.suspend(server)
    send(server, {:turn_cost, e["work_session"], 0.01})
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, e["work_session"])

    send(
      pid,
      {:stub,
       [
         {:event, :assistant_text, %{text: card(%{"sleep_minutes" => 30})}},
         {:event, :turn_done, %{}}
       ]}
    )

    :sys.get_state(pid)
    :sys.resume(server)
    :sys.get_state(server)

    # The card said sleep, and was read before deciding: no turn on stale state.
    BackendStub.refute_turn()
    {:ok, e} = Employees.get(e["id"], server)
    assert_in_delta e["wake_at"] - System.system_time(:millisecond), 30 * 60_000, 5_000
  end

  test "a turn with no card sleeps until the heartbeat", %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小测", "heartbeat_min" => 90}, server)
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.await_turn()
    end_turn(e["work_session"], "Nothing to do.", server)

    {:ok, e} = Employees.get(e["id"], server)
    assert_in_delta e["wake_at"] - System.system_time(:millisecond), 90 * 60_000, 5_000
  end

  test "the chat writes down KPIs and can wake the work session", %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小研"}, server)
    {:ok, _} = Agent.submit(e["chat_session"], "please research X by Friday")
    BackendStub.await_turn()

    end_turn(
      e["chat_session"],
      card(%{
        "kpi_add" => [%{"title" => "Research X", "due" => "2026-10-30", "priority" => "high"}],
        "note_for_work" => "focus on the 2026 papers",
        "wake_now" => true
      }),
      server
    )

    {:ok, e} = Employees.get(e["id"], server)
    assert [%{"title" => "Research X", "priority" => "high", "status" => "todo"}] = e["kpis"]
    assert e["pending_notes"] == 1
    assert e["wake_at"] <= System.system_time(:millisecond)
  end

  test "spent, it stops and waits for the boss; what they approve counts for today",
       %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小码", "budget_usd" => 50}, server)
    send(server, {:turn_cost, e["work_session"], 51.5})
    :sys.get_state(server)

    {:ok, e} = Employees.get(e["id"], server)
    assert e["status"] == "approval"
    assert e["spent_today"] == 51.5

    # Due, but over budget: no wake-up.
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.refute_turn()

    {:ok, e} = Employees.approve(e["id"], 20, server)
    assert e["cap_today"] == 70.0
    assert e["status"] == "sleeping"
  end

  test "a backend that reports no cost is held to turns a day", %{server: server} do
    {:ok, e} =
      Employees.create(%{"name" => "小基", "backend" => "kiro", "budget_turns" => 2}, server)

    assert Agent.info(e["work_session"]).backend == :kiro
    assert BackendStub.last_meta().kiro_model == "claude-opus-5.5"
    assert e["budget_unit"] == "turns"
    assert e["cap_today"] == 2.0

    for _ <- 1..2 do
      {:ok, _} = Employees.wake(e["id"], nil, server)
      BackendStub.await_turn()
      end_turn(e["work_session"], "Done.", server)
    end

    {:ok, e} = Employees.get(e["id"], server)
    assert e["spent_today"] == 2.0
    assert e["status"] == "approval"
    {:ok, e} = Employees.approve(e["id"], 5, server)
    assert e["cap_today"] == 7.0
  end

  test "the backend is chosen at hiring, and only from those there are", %{server: server} do
    assert {:error, _} = Employees.create(%{"name" => "a", "backend" => "gpt"}, server)
    {:ok, e} = Employees.create(%{"name" => "a"}, server)
    assert e["backend"] == "claude_code" and e["budget_unit"] == "usd"
  end

  test "paused, it does not wake", %{server: server} do
    {:ok, e} = Employees.create(%{"name" => "小测"}, server)
    {:ok, e} = Employees.pause(e["id"], true, server)
    assert e["status"] == "paused"
    {:ok, _} = Employees.wake(e["id"], nil, server)
    BackendStub.refute_turn()
  end

  test "settings are checked", %{server: server} do
    assert {:error, "an employee needs a name"} = Employees.create(%{"role" => "x"}, server)

    assert {:error, "no such project"} =
             Employees.create(%{"name" => "a", "project_ids" => ["p_nope"]}, server)

    assert {:error, _} = Employees.create(%{"name" => "a", "daily_report" => "25:00"}, server)
  end
end
