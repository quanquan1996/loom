defmodule LoomWeb.TidyControllerTest do
  @moduledoc """
  `loom-session`: what an agent may tidy is decided here, as a whitelist, and
  nothing it does deletes.
  """
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-tidy-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    caller = start!(title: "tidying")
    {:ok, caller: caller}
  end

  defp start!(opts) do
    id = Agent.new_id()
    {:ok, _} = Agent.start_session(id, [{:backend, :claude_code} | opts])
    id
  end

  defp cli(caller) do
    build_conn()
    |> put_req_header("x-loom-key", Loom.Nodes.cli_key())
    |> put_req_header("x-loom-session", caller)
    |> put_req_header("content-type", "application/json")
  end

  defp ids(conn), do: conn |> json_response(200) |> Map.fetch!("sessions") |> Enum.map(& &1["id"])

  test "lists only Recents: no pinned, employee, Dream or bell session", %{caller: caller} do
    plain = start!(title: "plain")
    pinned = start!(title: "pinned")
    :ok = Agent.pin(pinned, true)
    dream = start!(kind: "dream")
    work = start!(kind: "employee_work", employee: "e_1")
    bell = start!(kind: "bell")

    listed = ids(get(cli(caller), "/api/tidy/list"))
    assert plain in listed and caller in listed
    for hidden <- [pinned, dream, work, bell], do: refute(hidden in listed)

    for hidden <- [pinned, dream, work, bell] do
      conn = post(cli(caller), "/api/tidy/archive", %{ids: [hidden]})
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "not in Recents"
    end
  end

  test "archiving only marks it; writing in it brings it back", %{caller: caller} do
    s = start!(title: "done")
    conn = post(cli(caller), "/api/tidy/archive", %{ids: [s]})
    assert json_response(conn, 200)["ok"]

    assert is_integer(Agent.info(s).archived_at)
    assert Agent.exists?(s)
    refute s in ids(get(cli(caller), "/api/tidy/list"))
    assert s in ids(get(cli(caller), "/api/tidy/list", %{archived: "1"}))

    Process.sleep(2)
    {:ok, _} = Agent.submit(s, "one more thing")
    assert s in ids(get(cli(caller), "/api/tidy/list"))
  end

  test "unarchive clears the mark", %{caller: caller} do
    s = start!(title: "back")
    :ok = Agent.archive(s, true)
    conn = post(cli(caller), "/api/tidy/archive", %{ids: [s], archived: false})
    assert json_response(conn, 200)["ok"]
    assert Agent.info(s).archived_at == nil
  end

  test "refuses the caller itself", %{caller: caller} do
    conn = post(cli(caller), "/api/tidy/archive", %{ids: [caller]})
    assert json_response(conn, 422)["error"] =~ "you are in"
  end

  test "merge makes a new session seeded with the summary and archives the sources",
       %{caller: caller} do
    a = start!(title: "icons")
    b = start!(title: "more icons")

    conn =
      post(cli(caller), "/api/tidy/merge", %{
        title: "Icons",
        summary: "Decided: monochrome.",
        ids: [a, b]
      })

    assert %{"id" => merged} = json_response(conn, 200)
    info = Agent.info(merged)
    assert info.title == "Icons"
    assert info.turns == 0
    assert is_integer(Agent.info(a).archived_at) and is_integer(Agent.info(b).archived_at)

    {:ok, %{events: events}} = Agent.attach(merged)
    assert [%{kind: :user, payload: %{origin: "tidy", text: "Decided: monochrome."}}] = events

    # The backend hears it ahead of the next message.
    {:ok, _} = Agent.submit(merged, "go on")
    assert_receive {:stub_turn, text}, 1000
    assert text =~ "Decided: monochrome."
    assert text =~ "go on"
  end

  test "a handoff is a new session in Recents that begins with the brief", %{caller: caller} do
    conn =
      post(cli(caller), "/api/tidy/handoff", %{
        title: "供应商比价",
        brief: "老板同意转交：比较三家供应商。",
        project: "home"
      })

    assert %{"id" => id, "project_id" => nil} = json_response(conn, 200)
    info = Agent.info(id)
    assert info.title == "供应商比价" and info.turns == 0 and info.kind == nil
    {:ok, %{events: events}} = Agent.attach(id)
    assert [%{kind: :user, payload: %{origin: "handoff", text: "老板同意转交：比较三家供应商。"}}] = events

    {:ok, _} = Agent.submit(id, "开始吧")
    assert_receive {:stub_turn, text}, 1000
    assert text =~ "handed this matter off to you"
    assert text =~ "比较三家供应商"

    # Started at once, when asked to.
    conn = post(cli(caller), "/api/tidy/handoff", %{title: "t", brief: "do it", start: true})
    assert %{"id" => _} = json_response(conn, 200)
    assert_receive {:stub_turn, text}, 1000
    assert text =~ "do it"

    conn = post(cli(caller), "/api/tidy/handoff", %{title: "t", brief: "x", project: "p_nope"})
    assert json_response(conn, 422)["error"] =~ "no such project"
  end

  test "merge needs two, within one project", %{caller: caller} do
    a = start!(title: "a")
    conn = post(cli(caller), "/api/tidy/merge", %{title: "t", summary: "s", ids: [a]})
    assert json_response(conn, 422)["error"] =~ "two"
  end

  test "retitles one the first message named, never one the user named", %{caller: caller} do
    auto = start!([])
    {:ok, _} = Agent.submit(auto, "我想挂个域名了，我route53的域名还有1个月过期")
    named = start!([])
    :ok = Agent.rename(named, "饮食记录")

    rows = get(cli(caller), "/api/tidy/list") |> json_response(200) |> Map.fetch!("sessions")
    by = Map.new(rows, &{&1["id"], &1["title_by"]})
    assert by[auto] == "auto" and by[named] == "user"

    conn = post(cli(caller), "/api/tidy/retitle", %{id: auto, title: "域名续费 · Route53"})
    assert json_response(conn, 200)["ok"]
    assert %{title: "域名续费 · Route53", title_by: "tidy"} = Agent.info(auto)

    conn = post(cli(caller), "/api/tidy/retitle", %{id: named, title: "别的"})
    assert json_response(conn, 422)["error"] =~ "the user named it"
    assert Agent.info(named).title == "饮食记录"

    # Made with a title is named by whoever made it, so kept too.
    conn = post(cli(caller), "/api/tidy/retitle", %{id: caller, title: "Session 整理"})
    assert json_response(conn, 422)["error"] =~ "the user named it"
  end

  test "what was tidied comes after what is new since", %{caller: caller} do
    old = start!(title: "old")
    new = start!(title: "new")
    conn = post(cli(caller), "/api/tidy/keep", %{ids: [old]})
    assert json_response(conn, 200)["ok"]

    assert ids(get(cli(caller), "/api/tidy/list", %{fresh: "1"})) |> Enum.member?(new)
    refute ids(get(cli(caller), "/api/tidy/list", %{fresh: "1"})) |> Enum.member?(old)
    listed = ids(get(cli(caller), "/api/tidy/list"))
    assert Enum.find_index(listed, &(&1 == new)) < Enum.find_index(listed, &(&1 == old))

    # Used again: new again.
    Process.sleep(2)
    {:ok, _} = Agent.submit(old, "back to it")
    assert old in ids(get(cli(caller), "/api/tidy/list", %{fresh: "1"}))
  end

  test "read gives each turn's messages without tools", %{caller: caller} do
    s = start!(title: "q")
    {:ok, _} = Agent.submit(s, "hello?")
    conn = get(cli(caller), "/api/tidy/read", %{id: s})

    assert %{"messages" => [%{"role" => "user", "text" => "hello?"} | _]} =
             json_response(conn, 200)
  end
end
