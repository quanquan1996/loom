defmodule Loom.DreamTest do
  # Not async: sessions, the backend map and CLAUDE_CONFIG_DIR are global.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias Loom.Dream

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-dream-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    previous_claude = System.get_env("CLAUDE_CONFIG_DIR")

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, Path.join(dir, "sessions"))
      |> Keyword.put(:workspace, Path.join(dir, "home"))
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    System.put_env("CLAUDE_CONFIG_DIR", Path.join(dir, "claude"))
    start_supervised!({BackendStub, notify: self()})

    name = :"dream_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Dream, name: name, path: Path.join(dir, "dream.json"), tick: :timer.hours(24)},
      id: name
    )

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)

      if previous_claude,
        do: System.put_env("CLAUDE_CONFIG_DIR", previous_claude),
        else: System.delete_env("CLAUDE_CONFIG_DIR")

      File.rm_rf(dir)
    end)

    {:ok, dream: name, dir: dir}
  end

  defp finish_turn(id) do
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
    send(pid, {:stub, [{:event, :turn_done, %{}}]})
    :sys.get_state(pid)
  end

  test "the memory directory is named the way Claude Code names it" do
    assert Dream.slug("/home/ubuntu/.loom/projects/p_CrEKECkw/workspace") ==
             "-home-ubuntu--loom-projects-p-CrEKECkw-workspace"

    assert Dream.slug("/home/ubuntu") == "-home-ubuntu"
  end

  test "the night window can run past midnight" do
    assert Dream.in_window?(3, [3, 6])
    refute Dream.in_window?(6, [3, 6])
    assert Dream.in_window?(23, [22, 2])
    assert Dream.in_window?(1, [22, 2])
    refute Dream.in_window?(12, [22, 2])
  end

  describe "due?" do
    # 04:00 in Shanghai.
    @night DateTime.to_unix(~U[2026-10-28 20:00:00Z], :millisecond)
    @state %{scopes: %{}, window: [3, 6], utc_offset: 480}

    defp session(attrs),
      do:
        Map.merge(
          %{
            id: "a_x",
            project_id: nil,
            kind: nil,
            status: :idle,
            last_active_at: @night - :timer.hours(2)
          },
          attrs
        )

    test "at night, with something new and everything quiet" do
      assert Dream.due?(@state, "home", [session(%{})], @night)
    end

    test "not by day" do
      refute Dream.due?(@state, "home", [session(%{})], @night + :timer.hours(6))
    end

    test "not with nothing new since the last sleep" do
      state = put_in(@state.scopes["home"], %{"last_run_at" => @night - :timer.hours(13)})

      refute Dream.due?(
               state,
               "home",
               [session(%{last_active_at: @night - :timer.hours(14)})],
               @night
             )
    end

    test "not twice in one night" do
      state = put_in(@state.scopes["home"], %{"last_run_at" => @night - :timer.hours(1)})

      refute Dream.due?(
               state,
               "home",
               [session(%{last_active_at: @night - :timer.minutes(50)})],
               @night
             )
    end

    test "not while a session is working, or was a moment ago" do
      refute Dream.due?(@state, "home", [session(%{status: :running})], @night)

      refute Dream.due?(
               @state,
               "home",
               [session(%{last_active_at: @night - :timer.minutes(5)})],
               @night
             )
    end

    test "only for the scope the sessions are in, and not when turned off" do
      refute Dream.due?(@state, "p_1", [session(%{})], @night)
      assert Dream.due?(@state, "p_1", [session(%{project_id: "p_1"})], @night)

      off = put_in(@state.scopes["home"], %{"enabled" => false})
      refute Dream.due?(off, "home", [session(%{})], @night)
    end

    test "the sleep session itself does not count as something new" do
      refute Dream.due?(@state, "home", [session(%{kind: "dream"})], @night)
    end
  end

  test "memories are read from their frontmatter, the index first", %{dir: dir} do
    memory = Dream.memory_dir("home")
    assert String.starts_with?(memory, Path.join(dir, "claude/projects/"))
    File.mkdir_p!(Path.join(memory, "archive"))
    File.write!(Path.join(memory, "MEMORY.md"), "- [Deploy](deploy.md) — ask first\n")

    File.write!(Path.join(memory, "deploy.md"), """
    ---
    name: deploy
    description: "Ask before deploying"
    metadata:
      type: feedback
    ---

    Ask first.
    """)

    File.write!(Path.join([memory, "archive", "old.md"]), "no frontmatter")

    assert [
             %{file: "MEMORY.md", archived: false},
             %{
               file: "deploy.md",
               name: "deploy",
               description: "Ask before deploying",
               type: "feedback"
             },
             %{file: "archive/old.md", name: "old", archived: true}
           ] = Dream.memories("home")
  end

  test "sleeping happens in a hidden session, with the whole prompt sent and a line shown",
       %{dream: dream} do
    {:ok, _} = Agent.start_session("a_work", backend: :claude_code, title: "Work")
    {:ok, _} = Agent.submit("a_work", "remember: deploys need a yes first")
    BackendStub.await_turn()
    finish_turn("a_work")

    assert {:ok, %{session: id, last_run_at: at}} = Dream.run("home", dream)
    assert is_integer(at)

    prompt = BackendStub.await_turn()
    assert prompt =~ "You are performing a sleep for sessions outside any project"
    assert prompt =~ ~s["Work" (a_work)]

    info = Agent.info(id)
    assert info.kind == "dream"
    assert info.title == "Sleep"
    assert {:ok, %{events: events}} = Agent.attach(id)

    assert Enum.any?(
             events,
             &(&1.kind == :user and &1.payload.text == "Dream · 1 session since the last one")
           )

    # Asked again mid-turn: it is already asleep.
    assert {:error, :sleeping} = Dream.run("home", dream)
    # And the session is the same one next time.
    assert {:ok, ^id} = Dream.open("home", dream)
  end

  test "a sleep can be undone", %{dream: dream} do
    memory = Dream.memory_dir("home")
    File.mkdir_p!(memory)
    File.write!(Path.join(memory, "keep.md"), "kept")

    assert {:ok, %{session: id}} = Dream.run("home", dream)
    BackendStub.await_turn()

    # What the night did.
    File.rm!(Path.join(memory, "keep.md"))
    File.write!(Path.join(memory, "new.md"), "made up")
    finish_turn(id)

    assert {:ok, %{can_undo: false}} = Dream.undo("home", dream)
    assert File.read!(Path.join(memory, "keep.md")) == "kept"
    refute File.exists?(Path.join(memory, "new.md"))
    assert {:error, :nothing_to_undo} = Dream.undo("home", dream)
  end

  test "what has been read is remembered, and only moves forward" do
    {:ok, _} = Agent.start_session("a_seen", backend: :claude_code)
    {:ok, _} = Agent.submit("a_seen", "hi")
    BackendStub.await_turn()
    seq = Agent.info("a_seen").seq

    assert :ok = Agent.seen("a_seen", seq + 100)
    assert Agent.info("a_seen").seen_seq == seq
    assert :ok = Agent.seen("a_seen", 0)
    assert Agent.info("a_seen").seen_seq == seq
  end
end
