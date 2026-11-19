defmodule Loom.Agent.Backend.KiroTest do
  # The ACP translation, as a pure function: no process, so writes go
  # nowhere. Messages are as kiro-cli 1.28.1 (v2) and 3.4.0 (v3) sent them.
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
    # The session's agent is selected first, then the prompt goes.
    assert h.pending == %{3 => :set_mode, 4 => :prompt}
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

  test "steering before the turn is under way is refused, so the session queues it" do
    assert {:error, _} = Kiro.steer(handle(%{phase: :opening}), "more")
  end

  test "a steer goes into the running turn; one never injected is the next prompt" do
    h = handle(%{pending: %{5 => :prompt}, announced?: true, next_id: 6})
    {:ok, h} = Kiro.steer(h, "also this")
    assert [{ours, "also this"}] = h.steers
    assert h.pending[6] == {:steer, ours}

    # Kiro renames it; injection under its name clears it.
    {h, []} = feed(h, [%{"jsonrpc" => "2.0", "id" => 6, "result" => %{"messageId" => "steer-x"}}])
    assert h.steers == [{"steer-x", "also this"}]

    # The prompt ends with it still pending: it goes on, no turn_done yet.
    {h, out} =
      feed(h, [%{"jsonrpc" => "2.0", "id" => 5, "result" => %{"stopReason" => "end_turn"}}])

    assert events(out) == []
    assert h.steers == []
    assert h.pending[7] == :prompt

    # Injected in time instead: nothing left over, the turn simply ends.
    h = handle(%{pending: %{5 => :prompt}, announced?: true, steers: [{"steer-y", "t"}]})

    {h, []} =
      feed(h, [
        update(%{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{"kiro" => %{"kind" => "steering_injected", "messageId" => "steer-y"}}
        })
      ])

    {_h, out} =
      feed(h, [%{"jsonrpc" => "2.0", "id" => 5, "result" => %{"stopReason" => "end_turn"}}])

    assert [{:turn_done, _}] = events(out)
  end

  test "v3: context usage, a summary, and a tool result in content" do
    {h, out} =
      feed(handle(%{announced?: true}), [
        update(%{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{"kiro" => %{"kind" => "context_usage", "usagePercentage" => 2.5}}
        }),
        update(%{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{"kiro" => %{"kind" => "summarization_completed"}}
        }),
        update(%{"sessionUpdate" => "tool_call", "toolCallId" => "t2", "kind" => "execute"}),
        update(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t2",
          "status" => "completed",
          "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "hi"}}]
        })
      ])

    assert h.context_tokens == 25_000
    assert [{:compacted, _}, {:tool_use, _}, {:tool_result, %{output: "hi"}}] = events(out)
  end

  test "a permission request is allowed once; a question for the user is answered" do
    # No process: the answers go nowhere, and nothing is emitted.
    {_h, out} =
      feed(handle(), [
        %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "session/request_permission",
          "params" => %{"options" => [%{"optionId" => "accept", "kind" => "allow_once"}]}
        },
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "_kiro/userInput", "params" => %{}}
      ])

    assert out == []
  end

  test "the agent file is markdown v3 reads: front matter, then the instructions" do
    file = Kiro.agent_file(handle(%{model: "claude-sonnet-5"}))
    assert [_, front, body] = String.split(file, "---\n", parts: 3)
    assert front =~ ~s(name: "loom-a_test")
    assert front =~ ~s(tools: "*")
    assert front =~ ~s(excludedTools: ["subagent_loom-*"])
    assert front =~ ~s(model: "claude-sonnet-5")
    assert front =~ ~s("capability":"all")
    assert front =~ ~s("effect":"allow")
    assert body == "be good\n"
    refute Kiro.agent_file(handle()) =~ "model:"
  end
end
