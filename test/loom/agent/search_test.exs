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
      |> Enum.map_join("\n", fn {{kind, text, at}, seq} ->
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
end
