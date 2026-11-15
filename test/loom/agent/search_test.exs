defmodule Loom.Agent.SearchTest do
  @moduledoc "Finding sessions by what was said in them."
  use ExUnit.Case, async: false

  alias Loom.Agent.{Search, Store}

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-search-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(previous, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  defp transcript(id, events) do
    File.mkdir_p!(Store.session_dir(id))

    body =
      events
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn
        {{kind, text, at, origin}, seq} ->
          Jason.encode!(%{at: at, seq: seq, kind: kind, payload: %{text: text, origin: origin}})

        {{kind, text, at}, seq} ->
          Jason.encode!(%{at: at, seq: seq, kind: kind, payload: %{text: text}})
      end)

    File.write!(Store.events_path(id), body <> "\n")
  end

  test "what the user and the agent said, any case, newest first" do
    transcript("a", [{"user", "Fix the Sidebar search", 1}, {"assistant_text", "Done.", 2}])
    transcript("b", [{"user", "hello", 3}, {"assistant_text", "The sidebar now folds.", 4}])
    transcript("c", [{"thinking", "sidebar, privately", 5}, {"user", "nothing here", 6}])

    assert [%{id: "b", seq: 2}, %{id: "a", seq: 1}] = Search.run(["a", "b", "c"], "SIDEBAR")
  end

  test "a snippet around the match, and nothing for an empty query" do
    long = String.duplicate("前文", 30) <> "关键字" <> String.duplicate("后文", 60)
    transcript("a", [{"user", long, 1}])

    assert [%{snippet: "…" <> snippet}] = Search.run(["a"], "关键字")
    assert snippet =~ "关键字"
    assert String.ends_with?(snippet, "…")
    assert Search.run(["a"], "  ") == []
  end

  test "quotes are matched in the text, not the escaped line" do
    transcript("a", [{"user", ~s(say "hi" twice), 1}])
    assert [%{id: "a"}] = Search.run(["a"], ~s("hi"))
  end

  test "words are all needed, each anywhere in the session" do
    transcript("a", [{"user", "deploy the OAC", 1}, {"assistant_text", "部署 done", 2}])
    transcript("b", [{"user", "OAC only", 3}])

    assert [%{id: "a"}] = Search.run(["a", "b"], "oac 部署")
  end

  describe "ranked" do
    @now 100 * 24 * 3600 * 1000
    @day 24 * 3600 * 1000

    defp info(id, kind, days_ago, extra \\ []),
      do: Map.merge(%{id: id, kind: kind, title: nil, turns: 1, last_active_at: @now - days_ago * @day}, Map.new(extra))

    test "first what the sidebar lists, by kind, age, then where the words are; then the rest" do
      transcript("own_week", [{"user", "loom search", 1, "phone"}])
      transcript("own_title", [{"user", "hi", 1, "desktop"}])
      transcript("own_said", [{"user", "hi", 1, "phone"}, {"assistant_text", "search it", 2}])
      transcript("own_mine", [{"user", "search please", 1, "phone"}])
      transcript("notice", [{"user", "ok search", 2, "notice"}])
      transcript("archived", [{"user", "search", 1, "phone"}])
      transcript("emp_chat", [{"user", "search", 1, "phone"}])
      transcript("work", [{"user", "Wake-up, search", 1, "employee"}])

      infos = [
        info("own_week", nil, 5),
        info("own_title", nil, 0.5, title: "Search page"),
        info("own_said", nil, 0.5),
        info("own_mine", nil, 0.5),
        info("notice", "notice", 0.1),
        info("archived", nil, 0.2, archived_at: @now),
        info("emp_chat", "employee_chat", 0.1, employee_id: "e"),
        info("work", "employee_work", 0.1, employee_id: "e")
      ]

      hits = Search.ranked(infos, "SEARCH", @now)

      assert Enum.map(hits, &{&1.id, &1.tier}) == [
               {"own_title", 1},
               {"own_mine", 1},
               {"own_said", 1},
               {"own_week", 1},
               {"notice", 1},
               {"archived", 2},
               {"emp_chat", 2},
               {"work", 2}
             ]

      assert %{match: "title", snippet: nil} = hd(hits)
    end

    test "an archived chat used since is listed again" do
      transcript("a", [{"user", "search", 1, "phone"}])
      assert [%{tier: 1}] = Search.ranked([info("a", nil, 0, archived_at: @now - @day)], "search", @now)
    end

    test "a word in the title and one in the talk" do
      transcript("a", [{"user", "deploy it", 1, "phone"}])
      assert [%{id: "a", match: "mine"}] = Search.ranked([info("a", nil, 0, title: "OAC")], "oac deploy", @now)
      assert [] = Search.ranked([info("a", nil, 0, title: "OAC")], "oac missing", @now)
    end
  end
end
