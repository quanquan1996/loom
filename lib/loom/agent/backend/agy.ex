defmodule Loom.Agent.Backend.Agy do
  @moduledoc """
  Google's Antigravity CLI over the Agent Client Protocol: `agy acp`, JSON-RPC
  on stdio, one process per session. The same shape as `Loom.Agent.Backend.Kiro`
  (spawned on the first turn, kept warm, a `Loom.Agent.Proc` so a turn outlives
  the node); what differs is below. Measured on agy 1.5.13, 2026-11-20.

  ## The handshake

  `initialize`, then `session/new` (the reply names the conversation) or
  `session/resume` by that id, then `session/prompt`. `session/resume` does not
  replay the conversation; `session/load` does, as `session/update`s, and is
  not used. A conversation agy no longer has is started afresh.

  ## The system prompt is appended

  `initialize` advertises `_meta.antigravity.systemPrompt.append`: the
  session's instructions go as `_meta` on new and on resume, so there is no
  agent file to write or forget.

  ## The model, and no permission requests

  `session/set_model` with a `modelId` from `agy models`
  (`gemini-4-neon-high`, …); the level of thinking is part of the id, so there
  are no efforts. A warm process changes model in place. Spawned with
  `--dangerously-skip-permissions`, as every Loom agent runs unasked; a
  permission request that comes anyway is allowed once.

  ## Usage, cancel, what is missing

  `usage_update` gives the context used and its size; the prompt's reply gives
  the turn's tokens, and no cost. `session/cancel` ends the turn with
  `cancelled`. There is no steering (the session queues the message) and no
  tool-call hook, so a session with a workstation (`Loom.Agent.Guard`) is
  refused. agy signs in with a personal Google account, and Google turns
  requests from cloud addresses away (429 from AWS, measured 2026-11-19): it
  is for a Loom at home.
  """
  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Jsonl
  alias Loom.Agent.Proc

  @impl Backend
  def start(session_id, meta), do: {:ok, new(session_id, meta, nil)}

  @impl Backend
  def resume(session_id, meta) do
    case Backend.meta_get(meta, :agy_session_id) do
      id when is_binary(id) -> {:ok, new(session_id, meta, id)}
      # Made, but restored before its first turn: nothing to resume yet.
      _ -> {:ok, new(session_id, meta, nil)}
    end
  end

  defp new(loom_id, meta, agy_id) do
    %{
      loom_id: loom_id,
      session_id: agy_id,
      cwd: Backend.meta_get(meta, :agy_cwd) || Backend.meta_get(meta, :cc_cwd) || default_cwd(),
      instructions: Backend.meta_get(meta, :instructions),
      model: Backend.meta_get(meta, :agy_model),
      # An incognito session's: spawned under `Loom.Agent.Sandbox`.
      sandbox: Backend.meta_get(meta, :sandbox) == true,
      # The running process, a `Loom.Agent.Proc`; nil when there is none.
      proc: nil,
      saved: nil,
      buffer: "",
      next_id: 1,
      # Request id => what it was, for matching replies.
      pending: %{},
      # :idle, :init (initialize sent), :opening (new or resume sent), :running.
      phase: :idle,
      # The turn's text, waiting for its session.
      prompt: nil,
      # The block being streamed: {block_id, :text | :thinking, text so far}.
      block: nil,
      # Whether this turn has said it is running; see `announce/1`.
      announced?: false,
      tools: %{},
      interrupted?: false,
      context_tokens: 0,
      context_window: nil,
      # What agy says the session is on (`currentModelId`), for `turn_done`.
      current_model: nil
    }
  end

  @impl Backend
  def run_turn(handle, text) when is_binary(text) do
    handle = %{handle | prompt: text, interrupted?: false, tools: %{}, block: nil}

    live? = handle.proc != nil and Proc.alive?(handle.proc)

    cond do
      live? and handle.phase == :idle -> {:ok, prompt(handle)}
      live? -> {:ok, handle}
      true -> spawn_process(teardown(handle))
    end
  end

  # Spawned with no prompt: the handshake runs and the session waits, idle.
  @impl Backend
  def warm(%{proc: proc} = handle) when proc != nil do
    if Proc.alive?(proc), do: {:ok, handle}, else: spawn_process(teardown(handle))
  end

  def warm(handle), do: spawn_process(handle)

  # ACP has no steering and agy adds none: the session queues the message.
  @impl Backend
  def steer(_handle, _text), do: {:error, "agy cannot be steered mid-turn"}

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
    %{agy_session_id: handle.session_id, agy_cwd: handle.cwd, agy_model: handle.model}
  end

  # In place on a warm process whose session is open; before that it goes with
  # the handshake. Back to the default (nil) there is no call for: the process
  # is let go of, and the next spawn names no model.
  @impl Backend
  def set_model(%{model: model} = handle, model), do: handle

  def set_model(%{proc: proc, session_id: sid, phase: phase} = handle, model)
      when is_binary(model) and model != "" and proc != nil and is_binary(sid) and
             phase in [:idle, :running] do
    select_model(%{handle | model: model})
  end

  def set_model(%{phase: phase} = handle, model) when phase in [:init, :opening],
    do: %{handle | model: model}

  def set_model(handle, model), do: %{teardown(handle) | model: model}

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
         {:ok, exe} <- executable() do
      File.mkdir_p!(handle.cwd)
      {exe, args} = sandboxed(handle, exe, ["acp", "--dangerously-skip-permissions"])

      with {:ok, proc} <- Proc.spawn(handle.loom_id, exe, args, handle.cwd) do
        init(%{handle | proc: proc, buffer: "", pending: %{}, phase: :init})
      end
    end
  end

  # A workstation's guard is a hook before every tool call, and agy has none.
  defp no_workstation(handle) do
    case Loom.Agent.Guard.rules(handle.loom_id) do
      %{"workstation" => ws} when ws not in [nil, ""] ->
        {:error, "a workstation needs Claude Code: agy runs no tool-call hooks"}

      _ ->
        :ok
    end
  end

  # agy keeps its login, conversations and logs in ~/.gemini, written as it goes.
  defp sandboxed(%{sandbox: sandbox}, exe, args) when sandbox != true,
    do: Loom.Agent.Sandbox.guard_claude(exe, args)

  defp sandboxed(handle, exe, args) do
    Loom.Agent.Sandbox.wrap(
      true,
      exe,
      args,
      [handle.cwd, Loom.Agent.Store.output_dir(handle.loom_id), Path.expand("~/.gemini")] ++
        Loom.Agent.Sandbox.caches()
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
  # What new and resume carry. Public for the tests.
  def session_params(handle) do
    params = %{cwd: handle.cwd, mcpServers: []}

    case handle.instructions do
      text when is_binary(text) and text != "" ->
        Map.put(params, :_meta, %{antigravity: %{systemPrompt: %{append: text}}})

      _ ->
        params
    end
  end

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

  # `/compact` and agy's other commands are prompts that begin with a slash.
  defp prompt(%{prompt: text} = handle) do
    handle = %{handle | phase: :running, prompt: nil, announced?: false}
    params = %{sessionId: handle.session_id, prompt: [%{type: "text", text: text}]}
    send_rpc(handle, "session/prompt", params, :prompt)
  end

  defp select_model(%{model: model} = handle) when is_binary(model) and model != "" do
    params = %{sessionId: handle.session_id, modelId: model}

    handle
    |> send_rpc("session/set_model", params, :set_model)
    |> Map.put(:current_model, model)
  end

  defp select_model(handle), do: handle

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

    Enum.reduce(lines, {%{handle | buffer: buffer}, []}, fn line, {h, out} ->
      case Jason.decode(line) do
        {:ok, message} ->
          {h, produced} = translate(h, message)
          {h, out ++ produced}

        {:error, _} ->
          Logger.warning("agy: unparseable output line: #{String.slice(line, 0, 200)}")
          {h, out}
      end
    end)
  end

  @doc false
  # It went away on its own. Public for the tests.
  # Between turns (killed for memory, say) there is no turn to fail: the next
  # one spawns and resumes.
  def died(%{phase: :idle} = handle, _status),
    do: {:ok, %{handle | proc: nil, saved: nil, pending: %{}}, []}

  def died(handle, status) do
    {:ok, %{handle | proc: nil, saved: nil, phase: :idle, pending: %{}},
     close_block(handle) ++
       [
         {:event, :turn_failed,
          %{reason: "agy exited with status #{status || "?"} before finishing the turn"}}
       ]}
  end

  # Asked of us. Permission should not come (`--dangerously-skip-permissions`);
  # one that does is allowed once.
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

  # Files and terminals (refused at `initialize`), anything else: answered so
  # the agent does not wait.
  defp translate(handle, %{"id" => id, "method" => method}) when is_binary(method) do
    Logger.warning("agy: unexpected request #{method}")

    {write(handle, %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "not supported"}}),
     []}
  end

  # Replies.
  defp translate(handle, %{"id" => id} = message) when is_integer(id) do
    {what, pending} = Map.pop(handle.pending, id)
    reply(%{handle | pending: pending}, what, message)
  end

  defp translate(handle, %{"method" => "session/update", "params" => %{"update" => update}}) do
    case update do
      # Told at any time, a resume included: how full the context is.
      %{"sessionUpdate" => "usage_update"} -> {usage(handle, update), []}
      _ when handle.phase == :running -> announce(update(handle, update))
      _ -> {handle, []}
    end
  end

  defp translate(handle, _message), do: {handle, []}

  defp reply(handle, :initialize, %{"result" => _}) do
    params = session_params(handle)

    if handle.session_id do
      params = Map.put(params, :sessionId, handle.session_id)
      {send_rpc(%{handle | phase: :opening}, "session/resume", params, :resume), []}
    else
      {send_rpc(%{handle | phase: :opening}, "session/new", params, :new), []}
    end
  end

  defp reply(handle, :new, %{"result" => %{"sessionId" => id} = result}) do
    opened(current_model(%{handle | session_id: id}, result))
  end

  defp reply(handle, :resume, %{"result" => result}), do: opened(current_model(handle, result))

  # A conversation agy no longer has: started afresh rather than failing every
  # turn after. The history shown stays; the agent's is gone.
  defp reply(handle, :resume, %{"error" => error}) do
    Logger.warning("agy: cannot resume #{handle.session_id} (#{inspect(error)}); starting afresh")
    handle = %{handle | session_id: nil}
    {send_rpc(handle, "session/new", session_params(handle), :new), []}
  end

  defp reply(handle, :prompt, %{"result" => result}) do
    out = close_block(handle)
    handle = %{handle | phase: :idle, block: nil}

    if handle.interrupted? do
      # The cancel we asked for: the session says so itself.
      {%{handle | interrupted?: false}, []}
    else
      {handle,
       out ++
         [
           {:event, :turn_done,
            %{
              stop_reason: result["stopReason"],
              usage: turn_usage(result["usage"]),
              context_tokens: handle.context_tokens,
              context_window: handle.context_window,
              model: handle.current_model || handle.model
            }}
         ]}
    end
  end

  defp reply(handle, what, %{"error" => error}) when what in [:initialize, :new, :prompt] do
    out = close_block(handle)

    {%{handle | phase: :idle, block: nil, interrupted?: false},
     out ++ [{:event, :turn_failed, %{reason: "agy: " <> error_text(error)}}]}
  end

  defp reply(handle, :set_model, %{"error" => error}) do
    Logger.warning("agy: cannot set the model #{inspect(handle.model)}: #{error_text(error)}")
    {handle, []}
  end

  defp reply(handle, _what, _message), do: {handle, []}

  defp current_model(handle, %{"models" => %{"currentModelId" => model}}) when is_binary(model),
    do: %{handle | current_model: model}

  defp current_model(handle, _result), do: handle

  # The session is there: its model, then the turn — unless warmed with none.
  defp opened(handle), do: ready(select_model(handle))

  defp ready(%{prompt: nil} = handle), do: {%{handle | phase: :idle}, []}
  defp ready(handle), do: announce({prompt(handle), []})

  # A warm process starts a turn with no handshake to say so: the first thing
  # the turn does says it instead.
  defp announce({%{announced?: false} = handle, out}) do
    {%{handle | announced?: true},
     [{:event, :status, %{status: :running, backend_ref: handle.session_id}} | out]}
  end

  defp announce(result), do: result

  defp usage(handle, update) do
    handle =
      if is_integer(update["used"]), do: %{handle | context_tokens: update["used"]}, else: handle

    if is_integer(update["size"]) and update["size"] > 0,
      do: %{handle | context_window: update["size"]},
      else: handle
  end

  # In Claude Code's names, as the session adds them up.
  defp turn_usage(%{} = u) do
    %{
      "input_tokens" => u["inputTokens"] || 0,
      "output_tokens" => (u["outputTokens"] || 0) + (u["thoughtTokens"] || 0),
      "cache_read_input_tokens" => u["cachedReadTokens"] || 0,
      "cache_creation_input_tokens" => u["cachedWriteTokens"] || 0
    }
  end

  defp turn_usage(_), do: %{}

  # ── This turn's updates ──────────────────────────────────────────────────

  defp update(handle, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :text, text)

  defp update(handle, %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :thinking, text)

  # Told once per call, already under way; a second telling is not a new call.
  defp update(handle, %{"sessionUpdate" => "tool_call", "toolCallId" => id} = u)
       when not is_map_key(handle.tools, id) do
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

  defp update(handle, %{"sessionUpdate" => kind, "toolCallId" => id, "status" => status} = u)
       when kind in ["tool_call", "tool_call_update"] and status in ["completed", "failed"] do
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

  defp update(handle, _update), do: {handle, []}

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
    {"#{handle.session_id || "g?"}.#{System.unique_integer([:positive])}", %{handle | block: nil}}
  end

  # `kind` is the tool (`execute`, `read`, `edit`…); `name` is agy's own
  # (`run_command`), `title` what it does now.
  defp tool_name(u) do
    case u["kind"] do
      "execute" -> "Bash"
      "read" -> "Read"
      "edit" -> "Edit"
      "search" -> "Search"
      "fetch" -> "WebFetch"
      kind when is_binary(kind) and kind not in ["", "other"] -> kind
      _ -> u["name"] || u["title"] || "tool"
    end
  end

  # A shell command as Claude Code names it, so it reads the same in the chat.
  defp tool_input(u) do
    case u["rawInput"] || u["args"] do
      %{"CommandLine" => command} when is_binary(command) -> %{"command" => command}
      %{} = input -> Map.delete(input, "toolSummary")
      _ -> %{"title" => u["title"]}
    end
  end

  defp tool_output(u) do
    case {content_text(u["content"]), u["rawOutput"]} do
      {text, _} when text != "" -> text
      {_, %{"output" => text}} when is_binary(text) -> text
      {_, text} when is_binary(text) -> text
      {_, nil} -> ""
      {_, other} -> Jason.encode!(other)
    end
  end

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
    name = Application.get_env(:loom, Loom.Agent, [])[:agy_cli] || "agy"

    case System.find_executable(name) ||
           System.find_executable(Path.expand("~/.local/bin/" <> name)) do
      nil -> {:error, "could not find `#{name}` on PATH"}
      path -> {:ok, path}
    end
  end

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end
end
