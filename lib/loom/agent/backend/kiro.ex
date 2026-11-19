defmodule Loom.Agent.Backend.Kiro do
  @moduledoc """
  Kiro CLI over the Agent Client Protocol: `kiro-cli acp`, JSON-RPC on
  stdio, one process per session — Claude Code's model (see `ClaudeCode`):
  spawned on the first turn, kept warm between turns, killed by `release/1`.
  Measured on kiro-cli 1.28.1; 3.3.0 (2026-11-13) speaks the same ACP and
  loads conversations 1.28.1 wrote.

  ## A spawn is a handshake, then the turn

  `initialize`, then `session/new` (the first time; the reply names the
  conversation) or `session/load` (every time after, by that id), and only then
  `session/prompt`. All of it asynchronous: `run_turn/2` writes `initialize` and
  returns, and `decode/2` walks the rest as the replies come. The prompt waits
  in the handle until the session is there.

  `session/load` replays the whole conversation as `session/update`s before it
  answers. Those are history, not this turn, and are dropped.

  ## The v3 engine, and the system prompt is an agent

  Spawned as `kiro-cli acp --agent-engine v3 --auth-method cli`: any v2-only
  flag (`--trust-all-tools`, `--agent`, `--model`) silently selects the old
  engine (measured on 3.4.0). ACP has no system prompt; a Kiro *agent* has
  one, so each session gets its own, `~/.kiro/agents/loom-<session>.md`
  (front matter, then the instructions as the body), written before every
  spawn and selected with `session/set_mode` after new/load. Its permissions
  rule allows every tool, so no permission request comes. v3 opens
  conversations the v2 engine wrote. It does not run an agent file's hooks,
  so a session with a workstation (`Loom.Agent.Guard`) is refused.

  ## Killing is a process group

  `kiro-cli` is a launcher for `kiro-cli-chat`; the launcher killed, the child
  lives on and holds the conversation's lock ("Session is active in another
  process"), so the next `session/load` fails. The child is spawned directly,
  and killed with its descendants (`ClaudeCode.kill_tree/1`). From 3.x there
  is no `kiro-cli-chat`: `kiro-cli acp` is the one process, spawned the same
  way. 1.x servers refuse the client (`UnsupportedClientVersionException`).

  ## It outlives the node

  As for Claude Code, the process is a `Loom.Agent.Proc`, not a port. That
  matters more here: on a pipe, Kiro takes EOF on stdin as "quit" and drops
  the turn half done (measured), so a restart would always cut it off. On a
  FIFO it carries on, and the next node takes it back with `adopt/1`.

  ## Steering, compaction, no cost

  `_session/steer` queues a message into the running turn at its next
  boundary (`steering_injected`); one still pending when the prompt replies
  goes on as the next prompt. `/compact` is `_kiro/session/compact`. Kiro
  reports no cost, only how full the context is (`session_info_update`
  `context_usage`, a percentage), which becomes `context_tokens` against the
  model's window.
  """
  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Jsonl
  alias Loom.Agent.Proc

  # Every model Kiro lists has a window this size (`--list-models`).
  @window 1_000_000

  @impl Backend
  def start(session_id, meta), do: {:ok, new(session_id, meta, nil)}

  @impl Backend
  def resume(session_id, meta) do
    case Backend.meta_get(meta, :kiro_session_id) do
      id when is_binary(id) -> {:ok, new(session_id, meta, id)}
      # Made, but restored before its first turn: nothing to resume yet.
      _ -> {:ok, new(session_id, meta, nil)}
    end
  end

  defp new(loom_id, meta, kiro_id) do
    %{
      loom_id: loom_id,
      session_id: kiro_id,
      cwd: Backend.meta_get(meta, :kiro_cwd) || Backend.meta_get(meta, :cc_cwd) || default_cwd(),
      instructions: Backend.meta_get(meta, :instructions),
      model: Backend.meta_get(meta, :kiro_model),
      # An incognito session's: spawned under `Loom.Agent.Sandbox`.
      sandbox: Backend.meta_get(meta, :sandbox) == true,
      # The running process, a `Loom.Agent.Proc`; nil when there is none.
      proc: nil,
      saved: nil,
      buffer: "",
      next_id: 1,
      # Request id => what it was, for matching replies.
      pending: %{},
      # :idle, :init (initialize sent), :opening (new or load sent), :running.
      phase: :idle,
      # The turn's text, waiting for its session.
      prompt: nil,
      # The block being streamed: {block_id, :text | :thinking, text so far}.
      block: nil,
      # Whether this turn has said it is running; see `announce/2`.
      announced?: false,
      tools: %{},
      interrupted?: false,
      # Steers sent this turn and not yet injected: {message_id, text}.
      steers: [],
      context_tokens: 0,
      # What Kiro says the session is on (`currentModelId`), for `turn_done`.
      current_model: nil
    }
  end

  @impl Backend
  def run_turn(handle, text) when is_binary(text) do
    handle = %{handle | prompt: text, interrupted?: false, tools: %{}, block: nil, steers: []}

    live? = handle.proc != nil and Proc.alive?(handle.proc)

    cond do
      live? and handle.phase == :idle -> {:ok, prompt(handle)}
      live? -> {:ok, handle}
      true -> spawn_process(teardown(handle))
    end
  end

  # Spawned with no prompt: the handshake runs and the session waits, idle.
  # A message typed during the handshake waits for it, as on any spawn.
  @impl Backend
  def warm(%{proc: proc} = handle) when proc != nil do
    if Proc.alive?(proc), do: {:ok, handle}, else: spawn_process(teardown(handle))
  end

  def warm(handle), do: spawn_process(handle)

  # Into the running turn, at its next boundary (`steering_injected`). Before
  # the turn is under way there is nothing to steer: the session queues it.
  @impl Backend
  def steer(%{phase: :running, session_id: sid} = handle, text) when is_binary(sid) do
    ours = "loom-steer-#{System.unique_integer([:positive])}"
    params = %{sessionId: sid, message: text, messageId: ours}
    handle = send_rpc(handle, "_session/steer", params, {:steer, ours})
    {:ok, %{handle | steers: handle.steers ++ [{ours, text}]}}
  end

  def steer(_handle, _text), do: {:error, "no running kiro turn to steer"}

  @impl Backend
  def interrupt(%{proc: nil} = handle), do: {:ok, handle}

  def interrupt(%{phase: :running} = handle) do
    # A notification, not a request: the prompt's own reply says `cancelled`.
    {:ok,
     %{
       send_rpc(handle, "session/cancel", %{sessionId: handle.session_id}, nil)
       | interrupted?: true
     }}
  end

  # Not yet in a turn: nothing to cancel, so the spawn goes instead.
  def interrupt(handle), do: {:ok, teardown(handle)}

  @impl Backend
  def persist(handle) do
    %{kiro_session_id: handle.session_id, kiro_cwd: handle.cwd, kiro_model: handle.model}
  end

  # In the agent file, written at every spawn: a warm process on another model
  # is let go of, like Claude Code's.
  @impl Backend
  def set_model(handle, model) do
    if handle.model == model,
      do: handle,
      else: %{teardown(handle) | model: model}
  end

  @impl Backend
  def release(%{proc: nil} = handle), do: {:ok, handle}
  def release(handle), do: {:ok, teardown(handle)}

  @impl Backend
  def relocate(handle, cwd, instructions) do
    {:ok, %{teardown(handle) | cwd: cwd || default_cwd(), instructions: instructions}}
  end

  @impl Backend
  def stop(handle) do
    teardown(handle)
    :ok
  end

  defp teardown(%{proc: nil} = handle), do: handle

  defp teardown(handle) do
    Proc.kill(handle.proc)
    %{handle | proc: nil, saved: nil, buffer: "", phase: :idle, pending: %{}, block: nil}
  end

  @impl Backend
  def detach(%{proc: nil}), do: :ok

  def detach(handle) do
    checkpoint(handle)
    Proc.close(handle.proc)
  end

  @impl Backend
  def adopt(handle) do
    case Proc.adopt(handle.loom_id) do
      # The fresh handle's instructions win: they are written to the agent
      # file before the next spawn.
      {:ok, proc, saved} ->
        {:ok, %{Map.merge(handle, saved) | proc: proc, instructions: handle.instructions}}

      :error ->
        :error
    end
  end

  @impl Backend
  def checkpoint(%{proc: nil} = handle), do: handle

  def checkpoint(handle) do
    saved = Map.drop(handle, [:proc, :saved, :instructions])
    mark = :erlang.phash2({handle.proc.offset, saved})

    if mark == handle.saved do
      handle
    else
      Proc.checkpoint(handle.proc, saved)
      %{handle | saved: mark}
    end
  end

  # ── Spawning ────────────────────────────────────────────────────────────

  defp spawn_process(handle) do
    with :ok <- no_workstation(handle),
         {:ok, exe} <- executable(),
         :ok <- write_agent(handle) do
      File.mkdir_p!(handle.cwd)
      # The v3 engine, named: any v2-only flag (`--trust-all-tools`,
      # `--agent`, `--model`) silently selects the old one. The agent is
      # selected with `session/set_mode` once the session is open.
      args = ["acp", "--agent-engine", "v3", "--auth-method", "cli"]

      {exe, args} = sandboxed(handle, exe, args)

      with {:ok, proc} <- Proc.spawn(handle.loom_id, exe, args, handle.cwd) do
        handle = %{handle | proc: proc, buffer: "", pending: %{}, phase: :init}
        init(handle)
      end
    end
  end

  # A workstation's guard is a hook before every tool call, and the v3 engine
  # does not run an agent file's hooks (measured on 3.4.0: neither form fires).
  # So a guarded employee does not start on Kiro rather than run unchecked.
  defp no_workstation(handle) do
    case Loom.Agent.Guard.rules(handle.loom_id) do
      %{"workstation" => ws} when ws not in [nil, ""] ->
        {:error, "a workstation needs Claude Code: Kiro's v3 engine runs no tool-call hooks"}

      _ ->
        :ok
    end
  end

  # Kiro keeps ACP conversations in ~/.kiro/sessions and its login in
  # ~/.local/share/kiro-cli, both written as it goes; the knowledge bases
  # beside the login are memory, so they stay read-only.
  defp sandboxed(%{sandbox: sandbox} = _handle, exe, args) when sandbox != true,
    do: Loom.Agent.Sandbox.guard_claude(exe, args)

  defp sandboxed(handle, exe, args) do
    data = Path.expand("~/.local/share/kiro-cli")

    Loom.Agent.Sandbox.wrap(
      Map.get(handle, :sandbox),
      exe,
      args,
      [
        handle.cwd,
        Loom.Agent.Store.output_dir(handle.loom_id),
        Path.expand("~/.kiro/sessions"),
        # v3 indexes its sessions here as it opens them (EROFS otherwise).
        Path.expand("~/.kiro/session-index"),
        data
      ] ++ Loom.Agent.Sandbox.caches(),
      [Path.join(data, "knowledge_bases")]
    )
  end

  defp init(handle) do
    params = %{
      protocolVersion: 1,
      clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}, terminal: false},
      clientInfo: %{name: "loom", version: "1"}
    }

    {:ok, send_rpc(handle, "initialize", params, :initialize)}
  end

  @doc false
  def agent_name(handle), do: "loom-" <> handle.loom_id

  @doc "Where a session's agent (its system prompt) is kept."
  def agent_path(loom_id), do: Path.join([kiro_dir(), "agents", "loom-#{loom_id}.md"])

  # Before the v3 engine, a JSON agent named with `--agent`.
  defp legacy_agent_path(loom_id), do: Path.join([kiro_dir(), "agents", "loom-#{loom_id}.json"])

  @doc "A deleted session's agent goes with it, so `kiro-cli agent list` keeps only live ones."
  def forget(loom_id) do
    # `.json.bak`: kiro-cli's own backup when it upgraded the JSON agents.
    for path <- [
          agent_path(loom_id),
          legacy_agent_path(loom_id),
          legacy_agent_path(loom_id) <> ".bak"
        ],
        do: File.rm(path)

    :ok
  end

  @doc false
  # A markdown agent, as v3 reads them: front matter (each value JSON, which
  # is YAML), then the instructions as its body. Public for the tests.
  def agent_file(handle) do
    front =
      [
        name: agent_name(handle),
        description: "A Loom session (#{handle.loom_id}); written by Loom before every start.",
        tools: "*",
        # v3 offers every agent in ~/.kiro/agents as a sub-agent tool: the
        # other sessions' would be ~50 tools of context and a way to start
        # someone else's conversation by mistake.
        excludedTools: ["subagent_loom-*"],
        includeMcpJson: true,
        # Every tool call allowed, without a permission request; the user's
        # own Kiro settings stay as they are.
        permissions: %{rules: [%{capability: "all", effect: "allow"}]},
        resources: claude_rules(),
        model: handle.model
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{Jason.encode!(v)}" end)

    "---\n" <> front <> "\n---\n" <> (handle.instructions || "") <> "\n"
  end

  defp write_agent(handle) do
    path = agent_path(handle.loom_id)
    File.mkdir_p!(Path.dirname(path))
    File.rm(legacy_agent_path(handle.loom_id))
    File.rm(legacy_agent_path(handle.loom_id) <> ".bak")
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, agent_file(handle)),
         :ok <- File.chmod(tmp, 0o600),
         do: File.rename(tmp, path)
  end

  # Claude Code's global rules, read natively, so Kiro shares them. Its skills
  # and MCP servers are not mirrored: the rules tell other backends to read
  # skills as files and call MCP through a shell tool, so Claude Code stays the
  # one place they are configured. Kiro's own skill folder is kept, as naming
  # any resource replaces its default.
  defp claude_rules do
    rules = Path.join(claude_dir(), "CLAUDE.md")

    if(File.exists?(rules), do: ["file://" <> rules], else: []) ++
      ["skill://" <> Path.join([kiro_dir(), "skills", "*", "SKILL.md"])]
  end

  defp claude_dir, do: System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude")

  defp send_rpc(handle, method, params, nil) do
    write(handle, %{jsonrpc: "2.0", method: method, params: params})
  end

  defp send_rpc(handle, method, params, what) do
    id = handle.next_id
    handle = write(handle, %{jsonrpc: "2.0", id: id, method: method, params: params})
    %{handle | next_id: id + 1, pending: Map.put(handle.pending, id, what)}
  end

  defp write(handle, message) do
    if handle.proc, do: Proc.write(handle.proc, Jsonl.line(message))
    handle
  end

  # `/compact` typed as text would just be read: it is the engine's own call,
  # which replies `{success}` once the summary is done (~12 s).
  defp prompt(%{prompt: text} = handle) do
    handle = %{handle | phase: :running, prompt: nil, announced?: false}

    if String.trim(text) == "/compact" do
      send_rpc(handle, "_kiro/session/compact", %{sessionId: handle.session_id}, :prompt)
    else
      send_text(handle, text)
    end
  end

  defp send_text(handle, text) do
    params = %{sessionId: handle.session_id, prompt: [%{type: "text", text: text}]}
    send_rpc(handle, "session/prompt", params, :prompt)
  end

  # After new or load, before anything else: this session's agent, and its
  # model as the `model` config option (v3 reports the agent file's `model`
  # as `auto`; `session/set_model` is refused).
  defp select_agent(handle) do
    params = %{sessionId: handle.session_id, modeId: agent_name(handle)}
    handle = send_rpc(handle, "session/set_mode", params, :set_mode)

    case handle.model do
      model when is_binary(model) and model != "" ->
        params = %{sessionId: handle.session_id, configId: "model", value: model}

        handle
        |> send_rpc("session/set_config_option", params, :set_model)
        |> Map.put(:current_model, model)

      _ ->
        handle
    end
  end

  # ── Decoding ────────────────────────────────────────────────────────────

  @impl Backend
  def decode(%{proc: %Proc{ref: ref} = proc} = handle, {:loom_proc, ref}) do
    case Proc.poll(proc) do
      {"", proc, :alive} ->
        {:ok, %{handle | proc: proc}, []}

      {data, proc, :alive} ->
        {handle, out} = feed(%{handle | proc: proc}, data)
        {:ok, handle, out}

      {"", _proc, {:exited, status}} ->
        died(handle, status)
    end
  end

  # A poll for a process we have let go of.
  def decode(handle, {:loom_proc, _ref}), do: {:ok, handle, []}

  def decode(_handle, _message), do: :ignore

  @doc false
  # Output as read: lines may be split anywhere. Public for the tests.
  def feed(handle, chunk) do
    {lines, buffer} = Jsonl.split(handle.buffer <> chunk)

    {handle, out} =
      Enum.reduce(lines, {%{handle | buffer: buffer}, []}, fn line, {h, out} ->
        case Jason.decode(line) do
          {:ok, message} ->
            {h, produced} = translate(h, message)
            {h, out ++ produced}

          {:error, _} ->
            Logger.warning("Kiro: unparseable output line: #{String.slice(line, 0, 200)}")
            {h, out}
        end
      end)

    {handle, out}
  end

  @doc false
  # It went away on its own. Public for the tests.
  def died(handle, status) do
    {:ok, %{handle | proc: nil, saved: nil, phase: :idle, pending: %{}},
     close_block(handle) ++
       [
         {:event, :turn_failed,
          %{reason: "kiro exited with status #{status || "?"} before finishing the turn"}}
       ]}
  end

  # Replies.
  defp translate(handle, %{"id" => id} = message) when is_integer(id) do
    {what, pending} = Map.pop(handle.pending, id)
    reply(%{handle | pending: pending}, what, message)
  end

  defp translate(handle, %{"method" => "session/update", "params" => %{"update" => update}}) do
    # A load's replay of the conversation so far is history, not this turn.
    if handle.phase == :running, do: announce(update(handle, update)), else: {handle, []}
  end

  defp translate(handle, %{"method" => "_kiro.dev/metadata", "params" => params}) do
    case params["contextUsagePercentage"] do
      pct when is_number(pct) -> {%{handle | context_tokens: round(pct / 100 * @window)}, []}
      _ -> {handle, []}
    end
  end

  # Asked of us. Permission should not come (the agent allows all); one that
  # does is allowed once. A question for the user: nobody is there to ask.
  defp translate(handle, %{"id" => id, "method" => "session/request_permission"} = m) do
    options = get_in(m, ["params", "options"]) || []

    choice =
      Enum.find(options, &(&1["kind"] == "allow_once")) ||
        Enum.find(options, &(&1["kind"] == "allow_always"))

    outcome =
      case choice do
        %{"optionId" => option} -> %{outcome: "selected", optionId: option}
        _ -> %{outcome: "cancelled"}
      end

    {write(handle, %{jsonrpc: "2.0", id: id, result: %{outcome: outcome}}), []}
  end

  defp translate(handle, %{"id" => id, "method" => "_kiro/userInput"}) do
    answer =
      "The user is not available to answer questions mid-turn. " <>
        "Use your best judgement, say what you assumed, and continue."

    {write(handle, %{jsonrpc: "2.0", id: id, result: %{action: "answered", answer: answer}}), []}
  end

  # Files and terminals (refused at `initialize`), anything else: answered so
  # the agent does not wait.
  defp translate(handle, %{"id" => id, "method" => method}) do
    Logger.warning("Kiro: unexpected request #{method}")

    {write(handle, %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "not supported"}}),
     []}
  end

  defp translate(handle, _message), do: {handle, []}

  defp reply(handle, :initialize, %{"result" => _}) do
    if handle.session_id do
      # Without `noReplay` the load replays the whole conversation first.
      params = %{
        sessionId: handle.session_id,
        cwd: handle.cwd,
        mcpServers: [],
        _meta: %{kiro: %{noReplay: true}}
      }

      {send_rpc(%{handle | phase: :opening}, "session/load", params, :load), []}
    else
      params = %{cwd: handle.cwd, mcpServers: []}
      {send_rpc(%{handle | phase: :opening}, "session/new", params, :new), []}
    end
  end

  defp reply(handle, :new, %{"result" => %{"sessionId" => id} = result}) do
    opened(current_model(%{handle | session_id: id}, result))
  end

  defp reply(handle, :load, %{"result" => result}), do: opened(current_model(handle, result))

  # A conversation Kiro no longer has: started afresh rather than failing every
  # turn after. The history shown stays; the agent's is gone.
  defp reply(handle, :load, %{"error" => error}) do
    Logger.warning("Kiro: cannot load #{handle.session_id} (#{inspect(error)}); starting afresh")
    params = %{cwd: handle.cwd, mcpServers: []}
    {send_rpc(%{handle | session_id: nil}, "session/new", params, :new), []}
  end

  # Steered text the engine had no boundary left for: it goes on as the next
  # prompt, in the same turn as far as Loom is concerned.
  defp reply(%{steers: [_ | _], interrupted?: false} = handle, :prompt, %{"result" => _}) do
    out = close_block(handle)
    text = Enum.map_join(handle.steers, "\n\n", fn {_id, text} -> text end)
    {send_text(%{handle | steers: [], block: nil}, text), out}
  end

  defp reply(handle, :prompt, %{"result" => %{"success" => false}}) do
    {%{handle | phase: :idle, block: nil, steers: []},
     close_block(handle) ++ [{:event, :turn_failed, %{reason: "kiro: compaction failed"}}]}
  end

  defp reply(handle, :prompt, %{"result" => result}) do
    out = close_block(handle)
    handle = %{handle | phase: :idle, block: nil, steers: []}

    cond do
      handle.interrupted? ->
        # The cancel we asked for: the session says so itself.
        {%{handle | interrupted?: false}, []}

      true ->
        {handle,
         out ++
           [
             {:event, :turn_done,
              %{
                stop_reason: result["stopReason"],
                usage: %{},
                context_tokens: handle.context_tokens,
                context_window: @window,
                model: Map.get(handle, :current_model) || handle.model
              }}
           ]}
    end
  end

  defp reply(handle, what, %{"error" => error}) when what in [:initialize, :new, :prompt] do
    out = close_block(handle)

    {%{handle | phase: :idle, block: nil},
     out ++ [{:event, :turn_failed, %{reason: "kiro: " <> error_text(error)}}]}
  end

  # Kiro renames a steer (`steer-` in front of ours); `steering_injected`
  # uses its name. Refused: it never queued, so it is not resent either.
  defp reply(handle, {:steer, ours}, %{"result" => %{"messageId" => theirs}})
       when is_binary(theirs) do
    steers =
      Enum.map(handle.steers, fn
        {^ours, t} -> {theirs, t}
        other -> other
      end)

    {%{handle | steers: steers}, []}
  end

  defp reply(handle, {:steer, ours}, %{"error" => error}) do
    Logger.warning("Kiro: steer refused: #{error_text(error)}")
    {%{handle | steers: List.keydelete(handle.steers, ours, 0)}, []}
  end

  defp reply(handle, :set_model, %{"error" => error}) do
    Logger.warning("Kiro: cannot set the model #{inspect(handle.model)}: #{error_text(error)}")
    {handle, []}
  end

  defp reply(handle, :set_mode, %{"error" => error}) do
    Logger.warning("Kiro: cannot select the session's agent: #{error_text(error)}")
    {handle, []}
  end

  defp reply(handle, _what, _message), do: {handle, []}

  defp current_model(handle, %{"models" => %{"currentModelId" => model}}) when is_binary(model),
    do: Map.put(handle, :current_model, model)

  # v3 has no `models`: the model is a config option.
  defp current_model(handle, %{"configOptions" => options}) when is_list(options) do
    case Enum.find(options, &(&1["id"] == "model")) do
      %{"currentValue" => model} when is_binary(model) -> Map.put(handle, :current_model, model)
      _ -> handle
    end
  end

  defp current_model(handle, _result), do: handle

  # The session is there; the turn begins — unless it was warmed with none.
  defp opened(handle), do: ready(select_agent(handle))

  defp ready(%{prompt: nil} = handle), do: {%{handle | phase: :idle}, []}

  # The session is there; the turn begins.
  defp ready(handle) do
    announce({prompt(handle), []})
  end

  # A warm process starts a turn with no handshake to say so: the first thing
  # the turn does says it instead.
  defp announce({%{announced?: false} = handle, out}) do
    {%{handle | announced?: true},
     [{:event, :status, %{status: :running, backend_ref: handle.session_id}} | out]}
  end

  defp announce(result), do: result

  # ── This turn's updates ──────────────────────────────────────────────────

  defp update(handle, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :text, text)

  defp update(handle, %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :thinking, text)

  defp update(handle, %{"sessionUpdate" => "tool_call", "toolCallId" => id} = u) do
    out = close_block(handle)
    {block_id, handle} = next_block(%{handle | block: nil})
    name = tool_name(u)
    handle = %{handle | tools: Map.put(handle.tools, id, name)}

    {handle,
     out ++
       [
         {:delta, %{block_id: block_id, type: :tool_use_start, name: name, id: id}},
         {:event, :tool_use, %{id: id, block_id: block_id, name: name, input: tool_input(u)}}
       ]}
  end

  defp update(
         handle,
         %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status} = u
       )
       when status in ["completed", "failed"] do
    {handle,
     [
       {:event, :tool_result,
        %{
          id: id,
          name: Map.get(handle.tools, id, "tool"),
          status: if(status == "failed", do: :error, else: :ok),
          output: tool_output(u)
        }}
     ]}
  end

  defp update(handle, %{"sessionUpdate" => "session_info_update"} = u),
    do: info(handle, get_in(u, ["_meta", "kiro"]) || %{})

  defp update(handle, _update), do: {handle, []}

  defp info(handle, %{"kind" => "context_usage"} = kiro) do
    case kiro["usagePercentage"] || get_in(kiro, ["contextUsage", "usagePercentage"]) do
      pct when is_number(pct) -> {%{handle | context_tokens: round(pct / 100 * @window)}, []}
      _ -> {handle, []}
    end
  end

  defp info(handle, %{"kind" => "steering_injected", "messageId" => id}),
    do: {%{handle | steers: List.keydelete(handle.steers, id, 0)}, []}

  # An automatic summary at the threshold (80 %), or the one `/compact` asked for.
  defp info(handle, %{"kind" => "summarization_completed"} = kiro) do
    if get_in(kiro, ["summarization", "status"]) in [nil, "success"],
      do: {handle, [{:event, :compacted, %{trigger: "kiro"}}]},
      else: {handle, []}
  end

  defp info(handle, %{"kind" => "model_fallback"} = kiro) do
    Logger.warning(
      "Kiro: model fallback #{inspect(kiro["from"])} -> #{inspect(kiro["to"])}: #{kiro["reason"]}"
    )

    {handle, []}
  end

  defp info(handle, _kiro), do: {handle, []}

  # Streamed text: a block opened on its first chunk and kept until something
  # else comes, when it becomes one event.
  defp chunk(%{block: {block_id, type, acc}} = handle, type, text) do
    {%{handle | block: {block_id, type, acc <> text}},
     [{:delta, %{block_id: block_id, type: type, chunk: text}}]}
  end

  defp chunk(handle, type, text) do
    out = close_block(handle)
    {block_id, handle} = next_block(handle)

    {%{handle | block: {block_id, type, text}},
     out ++
       [
         {:delta, %{block_id: block_id, type: :block_start, block_type: type}},
         {:delta, %{block_id: block_id, type: type, chunk: text}}
       ]}
  end

  defp close_block(%{block: {block_id, :text, text}}),
    do: [
      {:delta, %{block_id: block_id, type: :block_end}},
      {:event, :assistant_text, %{block_id: block_id, text: text}}
    ]

  defp close_block(%{block: {block_id, :thinking, text}}),
    do: [
      {:delta, %{block_id: block_id, type: :block_end}},
      {:event, :thinking, %{block_id: block_id, text: text}}
    ]

  defp close_block(_handle), do: []

  # Unique across turns and spawns, as the transcript keeps them all.
  defp next_block(handle) do
    {"#{handle.session_id || "k?"}.#{System.unique_integer([:positive])}", %{handle | block: nil}}
  end

  # `kind` is the tool (`execute`, `read`, `edit`…); `title` is what it does now.
  defp tool_name(u) do
    case u["kind"] do
      "execute" -> "Bash"
      "read" -> "Read"
      "edit" -> "Edit"
      "search" -> "Search"
      "fetch" -> "WebFetch"
      kind when is_binary(kind) -> kind
      _ -> u["title"] || "tool"
    end
  end

  defp tool_input(u) do
    case u["rawInput"] do
      %{} = input -> Map.delete(input, "__tool_use_purpose")
      _ -> %{"title" => u["title"]}
    end
  end

  # v3 puts the result in `content`; v2 in `rawOutput`.
  defp tool_output(u) do
    case {content_text(u["content"]), u["rawOutput"]} do
      {text, _} when text != "" -> text
      {_, %{"items" => items}} when is_list(items) -> Enum.map_join(items, "\n", &item_text/1)
      {_, nil} -> ""
      {_, text} when is_binary(text) -> text
      {_, %{"output" => text}} when is_binary(text) -> text
      {_, other} -> Jason.encode!(other)
    end
  end

  defp item_text(%{"Json" => %{"stdout" => out, "stderr" => err} = j}) do
    [out, err, if(j["exit_status"] not in [nil, "exit status: 0"], do: j["exit_status"])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp item_text(%{"Text" => text}) when is_binary(text), do: text
  defp item_text(%{"Json" => json}), do: Jason.encode!(json)
  defp item_text(other), do: Jason.encode!(other)

  defp content_text(list) when is_list(list) do
    Enum.map_join(list, "\n", fn
      %{"content" => %{"text" => text}} -> text
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  defp content_text(_), do: ""

  defp error_text(%{"data" => data}) when is_binary(data), do: data
  defp error_text(%{"message" => message}), do: message
  defp error_text(error), do: inspect(error)

  # ── Misc ────────────────────────────────────────────────────────────────

  defp executable do
    names =
      case Application.get_env(:loom, Loom.Agent, [])[:kiro_cli] do
        nil -> ["kiro-cli-chat", "kiro-cli"]
        configured -> [configured]
      end

    found =
      Enum.find_value(names, fn name ->
        System.find_executable(name) ||
          System.find_executable(Path.expand("~/.local/bin/" <> name))
      end)

    case found do
      nil -> {:error, "could not find `#{Enum.join(names, "` or `")}` on PATH"}
      path -> {:ok, path}
    end
  end

  defp kiro_dir, do: Path.expand("~/.kiro")

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end
end
