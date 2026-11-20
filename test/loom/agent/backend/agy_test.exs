defmodule Loom.Agent.Backend.AgyTest do
  # The ACP translation, as a pure function: no process, so writes go
  # nowhere. Messages are as agy 1.5.13 sent them (2026-11-20).
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend.Agy

  defp handle(overrides \\ %{}) do
    {:ok, h} = Agy.start("a_test", %{cc_cwd: "/tmp", instructions: "be good"})
    Map.merge(h, Map.merge(%{phase: :running, session_id: "sid"}, overrides))
  end

  defp feed(handle, messages) do
    chunk = Enum.map_join(messages, "", &(Jason.encode!(&1) <> "\n"))
    Agy.feed(handle, chunk)
  end

  defp update(u),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "sid", "update" => u}
    }

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})

  @models %{
    "availableModels" => [%{"modelId" => "gemini-4-neon-high", "name" => "Gemini 4 Neon (High)"}],
    "currentModelId" => "gemini-4-neon-high"
  }

  test "the instructions are the system prompt's appendix, on new and on resume" do
    assert Agy.session_params(handle()) == %{
             cwd: "/tmp",
             mcpServers: [],
             _meta: %{antigravity: %{systemPrompt: %{append: "be good"}}}
           }

    refute Map.has_key?(Agy.session_params(handle(%{instructions: nil})), :_meta)
  end

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
      feed(h, [
        %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "new", "models" => @models}}
      ])

    assert h.session_id == "new"
    assert h.phase == :running
    assert h.pending == %{3 => :prompt}
    assert h.current_model == "gemini-4-neon-high"
    assert [{:status, %{status: :running, backend_ref: "new"}}] = events(out)
    assert Agy.persist(h).agy_session_id == "new"
  end

  test "a session with a model sets it before the prompt" do
    h =
      handle(%{
        phase: :opening,
        session_id: nil,
        model: "gemini-3.8-flash-low",
        prompt: "hi",
        pending: %{2 => :new},
        next_id: 3
      })

    {h, _} =
      feed(h, [
        %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "new", "models" => @models}}
      ])

    assert h.pending == %{3 => :set_model, 4 => :prompt}
    assert h.current_model == "gemini-3.8-flash-low"
  end

  test "a resumed conversation resumes; one agy has lost starts afresh" do
    h = handle(%{phase: :init, prompt: "again", pending: %{1 => :initialize}, next_id: 2})
    {h, []} = feed(h, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}])
    assert h.pending == %{2 => :resume}

    {h, []} =
      feed(h, [
        %{"jsonrpc" => "2.0", "id" => 2, "error" => %{"code" => -32000, "message" => "not found"}}
      ])

    assert h.session_id == nil
    assert h.pending == %{3 => :new}
  end

  test "a turn: a shell command, its result, the answer, the usage" do
    call = %{
      "toolCallId" => "call_1",
      "name" => "run_command",
      "status" => "in_progress",
      "kind" => "execute",
      "title" => "echo hi-from-box",
      "rawInput" => %{"CommandLine" => "echo hi-from-box", "toolSummary" => "Echo test string"}
    }

    {h, out} =
      feed(handle(%{pending: %{3 => :prompt}}), [
        update(%{"sessionUpdate" => "usage_update", "used" => 9007, "size" => 1_048_576}),
        update(Map.put(call, "sessionUpdate", "tool_call")),
        update(
          Map.merge(call, %{
            "sessionUpdate" => "tool_call_update",
            "status" => "completed",
            "rawOutput" => %{"output" => "Command output:\nhi-from-box\r\n", "exit_code" => 0},
            "content" => [
              %{
                "type" => "content",
                "content" => %{"type" => "text", "text" => "Command output:\nhi-from-box\r\n"}
              }
            ]
          })
        ),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "It printed "}
        }),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "`hi-from-box`."}
        }),
        update(%{"sessionUpdate" => "usage_update", "used" => 9151, "size" => 1_048_576}),
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "result" => %{
            "stopReason" => "end_turn",
            "usage" => %{
              "inputTokens" => 11_162,
              "outputTokens" => 166,
              "cachedReadTokens" => 6830,
              "cachedWriteTokens" => 0,
              "thoughtTokens" => 108,
              "totalTokens" => 18_158
            }
          }
        }
      ])

    assert h.phase == :idle

    assert [
             {:status, %{status: :running}},
             {:tool_use,
              %{id: "call_1", name: "Bash", input: %{"command" => "echo hi-from-box"}}},
             {:tool_result, %{id: "call_1", name: "Bash", status: :ok, output: output}},
             {:assistant_text, %{text: "It printed `hi-from-box`."}},
             {:turn_done, done}
           ] = events(out)

    assert output =~ "hi-from-box"
    assert done.stop_reason == "end_turn"
    assert done.context_tokens == 9151
    assert done.context_window == 1_048_576
    assert done.usage["input_tokens"] == 11_162
    assert done.usage["output_tokens"] == 274
    assert done.usage["cache_read_input_tokens"] == 6830
  end

  test "thinking is its own block" do
    {_h, out} =
      feed(handle(), [
        update(%{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => %{"type" => "text", "text" => "hmm"}
        }),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "391"}
        })
      ])

    assert [{:status, _}, {:thinking, %{text: "hmm"}}] = events(out)
  end

  test "a cancelled turn: the failed tool is told, the turn is not done twice" do
    {h, out} =
      feed(
        handle(%{interrupted?: true, tools: %{"call_2" => "Bash"}, pending: %{5 => :prompt}}),
        [
          update(%{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "call_2",
            "status" => "failed",
            "kind" => "execute",
            "rawOutput" => %{"output" => ""},
            "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => ""}}]
          }),
          %{"jsonrpc" => "2.0", "id" => 5, "result" => %{"stopReason" => "cancelled"}}
        ]
      )

    assert h.phase == :idle
    refute h.interrupted?
    assert [{:status, _}, {:tool_result, %{id: "call_2", status: :error}}] = events(out)
  end

  test "updates outside a turn are not this turn's, but the usage is kept" do
    {h, out} =
      feed(handle(%{phase: :idle}), [
        update(%{"sessionUpdate" => "session_info_update", "title" => "A title"}),
        update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "history"}
        }),
        update(%{"sessionUpdate" => "usage_update", "used" => 42, "size" => 1000})
      ])

    assert out == []
    assert h.context_tokens == 42
  end

  test "a failed prompt fails the turn with agy's own words" do
    {h, out} =
      feed(handle(%{pending: %{3 => :prompt}}), [
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "error" => %{"code" => -32000, "message" => "User location is not supported"}
        }
      ])

    assert h.phase == :idle
    assert [{:turn_failed, %{reason: "agy: User location is not supported"}}] = events(out)
  end

  test "a request it makes of us is answered, never taken for a reply" do
    h = handle(%{pending: %{7 => :prompt}})

    {h, []} =
      feed(h, [
        %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "session/request_permission",
          "params" => %{"options" => [%{"optionId" => "o1", "kind" => "allow_once"}]}
        }
      ])

    # Its id is its own numbering: our pending prompt 7 is still waiting.
    assert h.pending == %{7 => :prompt}
  end

  test "the model: unchanged is a no-op, a new one waits for the session" do
    h = handle(%{phase: :idle, model: "a"})
    assert Agy.set_model(h, "a") == h
    assert Agy.set_model(%{h | phase: :opening}, "b").model == "b"
    # No process: nothing to tell, the next spawn names it.
    assert Agy.set_model(h, "b").model == "b"
    assert Agy.set_model(h, nil).model == nil
  end

  test "a process that goes between turns fails nothing; mid-turn it fails the turn" do
    assert {:ok, %{proc: nil}, []} = Agy.died(handle(%{phase: :idle}), 137)
    assert {:ok, %{proc: nil, phase: :idle}, out} = Agy.died(handle(), 137)
    assert [{:turn_failed, %{reason: "agy exited with status 137" <> _}}] = events(out)
  end

  test "the backend is known by name" do
    assert Loom.Agent.Backend.parse("agy") == {:ok, :agy}
    assert Loom.Agent.Backend.impl(:agy) == Agy
    assert Loom.Agent.Backend.label(:agy) == "Antigravity"
    assert Loom.Agent.Backend.efforts(:agy) == []
  end
end
