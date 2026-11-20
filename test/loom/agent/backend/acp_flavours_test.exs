defmodule Loom.Agent.Backend.AcpFlavoursTest do
  # What CodeBuddy and Grok do their own way on top of `Backend.Acp`; the
  # shared translation is covered by the agy tests. No process: writes go
  # nowhere.
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend
  alias Loom.Agent.Backend.{CodeBuddy, Grok}

  defp handle(module, overrides) do
    {:ok, h} = module.start("a_test", %{cc_cwd: "/tmp", instructions: "be good"})
    Map.merge(h, overrides)
  end

  defp feed(module, handle, messages) do
    module.feed(handle, Enum.map_join(messages, "", &(Jason.encode!(&1) <> "\n")))
  end

  test "CodeBuddy: the model and the instructions are named when it is spawned" do
    assert CodeBuddy.spawn_args(handle(CodeBuddy, %{model: "glm-5.3"})) ==
             ["--acp", "-y", "--model", "glm-5.3", "--append-system-prompt", "be good"]

    assert CodeBuddy.spawn_args(handle(CodeBuddy, %{instructions: nil})) == ["--acp", "-y"]
    assert CodeBuddy.session_params(handle(CodeBuddy, %{})) == %{cwd: "/tmp", mcpServers: []}
  end

  test "Grok: rules before the subcommand, the model inside it" do
    assert Grok.spawn_args(handle(Grok, %{model: "grok-4.6"})) ==
             ["--rules", "be good", "agent", "--always-approve", "-m", "grok-4.6", "stdio"]

    assert Grok.spawn_args(handle(Grok, %{instructions: ""})) ==
             ["agent", "--always-approve", "stdio"]
  end

  test "CodeBuddy loads a conversation it has, and the replay is not a turn" do
    h =
      handle(CodeBuddy, %{
        phase: :init,
        session_id: "old",
        prompt: "hi",
        pending: %{1 => :initialize},
        next_id: 2
      })

    {h, []} = feed(CodeBuddy, h, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}])
    assert h.phase == :opening
    assert h.pending == %{2 => :resume}

    replay = %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "old",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "an old answer"}
        }
      }
    }

    {h, []} = feed(CodeBuddy, h, [replay])

    # Loaded (the reply is null): now the prompt goes, and the turn is running.
    {h, out} = feed(CodeBuddy, h, [%{"jsonrpc" => "2.0", "id" => 2, "result" => nil}])
    assert h.phase == :running
    assert [{:event, :status, %{status: :running, backend_ref: "old"}}] = out
  end

  test "Grok resumes by id, and its own notifications are dropped" do
    h =
      handle(Grok, %{
        phase: :init,
        session_id: "old",
        prompt: "hi",
        pending: %{1 => :initialize},
        next_id: 2
      })

    setup = %{
      "jsonrpc" => "2.0",
      "method" => "_x.ai/session/setup",
      "params" => %{"phase" => "auth", "sessionId" => nil}
    }

    {h, []} = feed(Grok, h, [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}, setup])
    assert h.pending == %{2 => :resume}
  end

  test "CodeBuddy: a tool call waits for its arguments, then its result is text" do
    # As 2.185.0 sent them (2026-11-20), without their _meta.
    up = fn u ->
      %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"update" => u}}
    end

    id = "chatcmpl-tool-1"
    h = handle(CodeBuddy, %{session_id: "sid", phase: :running, announced?: true})

    {h, out} =
      feed(CodeBuddy, h, [
        up.(%{
          "sessionUpdate" => "tool_call",
          "toolCallId" => id,
          "title" => "Bash",
          "kind" => "other",
          "status" => "in_progress",
          "rawInput" => %{}
        }),
        up.(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => id,
          "rawInput" => %{"command" => "echo lo"}
        })
      ])

    assert out == []

    {h, out} =
      feed(CodeBuddy, h, [
        up.(%{
          "sessionUpdate" => "tool_call",
          "toolCallId" => id,
          "status" => "pending",
          "title" => "`echo loom`",
          "kind" => "execute",
          "rawInput" => %{"command" => "echo loom"}
        })
      ])

    assert [{:delta, %{type: :tool_use_start, name: "Bash"}}, {:event, :tool_use, use}] = out
    assert %{id: ^id, name: "Bash", input: %{"command" => "echo loom"}} = use

    {_h, out} =
      feed(CodeBuddy, h, [
        up.(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => id,
          "status" => "completed",
          "rawOutput" => %{"type" => "text", "text" => "Stdout: loom"}
        })
      ])

    assert [{:event, :tool_result, %{id: ^id, name: "Bash", status: :ok, output: "Stdout: loom"}}] =
             out
  end

  test "a new model lets the process go: it is named at the next spawn" do
    h = handle(CodeBuddy, %{session_id: "sid", phase: :idle, model: "a"})
    assert CodeBuddy.set_model(h, "a") == h
    assert %{model: "b", proc: nil, session_id: "sid"} = CodeBuddy.set_model(h, "b")
  end

  test "each keeps its own keys in the session's header" do
    h = handle(Grok, %{session_id: "sid", model: "grok-4.6"})
    assert Grok.persist(h) == %{grok_session_id: "sid", grok_cwd: "/tmp", grok_model: "grok-4.6"}

    {:ok, h} = Grok.resume("a_test", %{grok_session_id: "sid", grok_cwd: "/x", grok_model: "m"})
    assert %{session_id: "sid", cwd: "/x", model: "m"} = h

    assert %{codebuddy_session_id: nil} = CodeBuddy.persist(handle(CodeBuddy, %{}))
  end

  test "both are known by name" do
    assert Backend.parse("codebuddy") == {:ok, :codebuddy}
    assert Backend.parse("grok") == {:ok, :grok}
    assert Backend.impl(:codebuddy) == CodeBuddy
    assert Backend.impl(:grok) == Grok
    assert Backend.label(:codebuddy) == "CodeBuddy"
  end
end
