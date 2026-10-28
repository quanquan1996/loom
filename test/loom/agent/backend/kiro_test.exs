defmodule Loom.Agent.Backend.KiroTest do
  # The ACP translation, as a pure function: no process, so writes go
  # nowhere. Messages are as kiro-cli 1.28.1 sent them.
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend.Kiro

  defp handle(overrides \\ %{}) do
    {:ok, h} = Kiro.start("a_test", %{cc_cwd: "/tmp", instructions: "be good"})
    Map.merge(h, Map.merge(%{phase: :running, session_id: "sid"}, overrides))
  end

  defp feed(handle, messages) do
    chunk = Enum.map_join(messages, "", &(Jason.encode!(&1) <> "\n"))
    Kiro.feed(handle, chunk)
  end

  defp update(u),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "sid", "update" => u}
    }

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})

  test "the handshake: initialize, then session/new, then the prompt" do
    h =
      handle(%{
        phase: :init,
        session_id: nil,
        prompt: "hi",
        pending: %{1 => :initialize},
        next_id: 2
      })

    {h, []} = feed(h, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"protocolVersion" => 1}}])
    assert h.phase == :opening
    assert h.pending == %{2 => :new}

    {h, out} =
      feed(h, [%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "new-sid"}}])

    assert h.session_id == "new-sid"
    assert h.phase == :running
    assert h.pending == %{3 => :prompt}
    assert [{:status, %{status: :running, backend_ref: "new-sid"}}] = events(out)
    assert Kiro.persist(h).kiro_session_id == "new-sid"
  end

  test "a resumed conversation loads, and its replay is not this turn" do
    h = handle(%{phase: :init, prompt: "again", pending: %{1 => :initialize}, next_id: 2})
    {h, []} = feed(h, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}])
    assert h.pending == %{2 => :load}

    {h, out} =
      feed(h, [
        update(%{
          "sessionUpdate" => "user_message_chunk",
          "content" => %{"type" => "text", "text" => "old"}
        }),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "old reply"}
        }),
        %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"modes" => %{}}}
      ])

    assert [{:status, %{status: :running}}] = events(out)
    refute Enum.any?(out, &match?({:delta, _}, &1))
    assert h.phase == :running
  end

  test "text streams as deltas and lands as one event; a tool call is a card" do
    {h, out} =
      feed(handle(), [
        update(%{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Running: ls",
          "kind" => "execute",
          "rawInput" => %{"command" => "ls", "__tool_use_purpose" => "look"}
        }),
        update(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "completed",
          "kind" => "execute",
          "rawOutput" => %{
            "items" => [
              %{
                "Json" => %{
                  "exit_status" => "exit status: 0",
                  "stdout" => "a.txt\n",
                  "stderr" => ""
                }
              }
            ]
          }
        }),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Done—"}
        }),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "one file."}
        }),
        %{
          "jsonrpc" => "2.0",
          "method" => "_kiro.dev/metadata",
          "params" => %{"contextUsagePercentage" => 1.5}
        }
      ])

    # The first update of a warm turn says it is running.
    assert [{:status, %{status: :running}} | rest] = events(out)

    assert [
             {:tool_use, %{id: "t1", name: "Bash", input: %{"command" => "ls"}}},
             {:tool_result, %{id: "t1", name: "Bash", status: :ok, output: "a.txt\n"}}
           ] = rest

    text = for {:delta, %{type: :text, chunk: c}} <- out, do: c
    assert text == ["Done—", "one file."]
    assert h.context_tokens == 15_000
    assert {_, :text, "Done—one file."} = h.block
  end

  test "the end of the turn closes the text and reports done" do
    h = handle(%{pending: %{5 => :prompt}, announced?: true, block: {"b1", :text, "All done."}})

    {h, out} =
      feed(h, [%{"jsonrpc" => "2.0", "id" => 5, "result" => %{"stopReason" => "end_turn"}}])

    assert [
             {:assistant_text, %{block_id: "b1", text: "All done."}},
             {:turn_done, %{stop_reason: "end_turn", context_window: 1_000_000}}
           ] = events(out)

    assert h.phase == :idle
  end

  test "a cancel we asked for is not reported as anything" do
    h = handle(%{pending: %{5 => :prompt}, announced?: true, interrupted?: true})

    {_h, out} =
      feed(h, [%{"jsonrpc" => "2.0", "id" => 5, "result" => %{"stopReason" => "cancelled"}}])

    assert events(out) == []
  end

  test "a failed prompt fails the turn, with Kiro's own words" do
    h = handle(%{pending: %{5 => :prompt}, announced?: true})

    {_h, out} =
      feed(h, [
        %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "error" => %{
            "code" => -32603,
            "message" => "Internal error",
            "data" => "No session found with id"
          }
        }
      ])

    assert [{:turn_failed, %{reason: "kiro: No session found with id"}}] = events(out)
  end

  test "steering is refused, so the session queues the message" do
    assert {:error, _} = Kiro.steer(handle(), "more")
  end

  test "Claude Code's MCP servers are carried over in Kiro's shape" do
    path = Path.join(System.tmp_dir!(), "claude-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "mcpServers" => %{
          "docs" => %{"type" => "stdio", "command" => "uvx", "args" => ["docs"], "env" => %{"A" => "1"}},
          "remote" => %{"type" => "http", "url" => "https://x.test/mcp", "headers" => %{"H" => "v"}},
          "odd" => %{"type" => "stdio"}
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    assert Kiro.claude_mcp_servers(path) == %{
             "docs" => %{command: "uvx", args: ["docs"], env: %{"A" => "1"}},
             "remote" => %{url: "https://x.test/mcp", headers: %{"H" => "v"}}
           }

    assert Kiro.claude_mcp_servers(path <> ".missing") == %{}
  end
end
