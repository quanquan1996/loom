defmodule Loom.Agent.Backend.Acp do
  @moduledoc """
  An agent CLI that speaks the Agent Client Protocol: JSON-RPC on stdio, one
  process per session, spawned on the first turn and kept warm, a
  `Loom.Agent.Proc` so a turn outlives the node. Everything the CLIs share is
  here; what one of them does its own way is a flavour — a module that
  `use`s this one and answers the callbacks below (`Backend.Agy`,
  `Backend.CodeBuddy`, `Backend.Grok`). Kiro has its own module, older than
  this one.

  ## The handshake

  `initialize`, then `session/new` (the reply names the conversation) or, for
  one the agent already has, `session/resume` — or `session/load` for a CLI
  with no resume, whose replay of the conversation is dropped. Then
  `session/prompt`. A conversation the agent no longer has is started afresh.

  ## The model, and no permission requests

  `session/set_model` on a warm process where the flavour takes it; otherwise
  the model is named when the process is spawned, and changing it lets the
  process go. Every flavour is spawned to run unasked, as every Loom agent
  does; a permission request that comes anyway is allowed once.

  ## Usage, cancel, what is missing

  `usage_update` gives the context used and its size; the prompt's reply gives
  the turn's tokens, and no cost. `session/cancel` ends the turn with
  `cancelled`. There is no steering (the session queues the message) and no
  tool-call hook, so a session with a workstation (`Loom.Agent.Guard`) is
  refused.
  """

  @doc "The CLI's name in logs and errors: `agy`."
  @callback name() :: String.t()
  @doc "The prefix of its keys in a session's header: `agy` for `agy_session_id`."
  @callback key() :: String.t()
  @doc "The names its binary may have on PATH, the configured one first."
  @callback executables() :: [String.t()]
  @doc "The arguments it is spawned with, for this session."
  @callback spawn_args(handle :: map()) :: [String.t()]
  @doc "`session/new`'s and resume's params, given the standard ones."
  @callback session_params(handle :: map(), params :: map()) :: map()
  @doc "How a conversation it already has is opened."
  @callback open() :: :resume | :load
  @doc "Its own directories, writable even in an incognito session."
  @callback state_dirs() :: [String.t()]
  @doc "Whether `session/set_model` changes the model of an open session."
  @callback model_in_place?() :: boolean()
  @doc "Whether the instructions go ahead of a new conversation's first message."
  @callback instructions_in_prompt?() :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour Loom.Agent.Backend
      @behaviour Loom.Agent.Backend.Acp

      alias Loom.Agent.Backend.Acp

      @impl Loom.Agent.Backend
      def start(session_id, meta), do: Acp.start(__MODULE__, session_id, meta)
      @impl Loom.Agent.Backend
      def resume(session_id, meta), do: Acp.resume(__MODULE__, session_id, meta)
      @impl Loom.Agent.Backend
      defdelegate run_turn(handle, text), to: Acp
      @impl Loom.Agent.Backend
      defdelegate warm(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate steer(handle, text), to: Acp
      @impl Loom.Agent.Backend
      defdelegate interrupt(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate persist(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate set_model(handle, model), to: Acp
      @impl Loom.Agent.Backend
      defdelegate release(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate relocate(handle, cwd, instructions), to: Acp
      @impl Loom.Agent.Backend
      defdelegate stop(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate detach(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate adopt(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate checkpoint(handle), to: Acp
      @impl Loom.Agent.Backend
      defdelegate decode(handle, message), to: Acp

      @doc false
      defdelegate feed(handle, chunk), to: Acp
      @doc false
      defdelegate died(handle, status), to: Acp
      @doc false
      defdelegate session_params(handle), to: Acp

      @impl Loom.Agent.Backend.Acp
      def open, do: :resume
      @impl Loom.Agent.Backend.Acp
      def model_in_place?, do: false
      @impl Loom.Agent.Backend.Acp
      def session_params(_handle, params), do: params
      @impl Loom.Agent.Backend.Acp
      def instructions_in_prompt?, do: false

      defoverridable open: 0, model_in_place?: 0, session_params: 2, instructions_in_prompt?: 0
    end
  end

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Jsonl
  alias Loom.Agent.Proc

  @doc false
  def start(flavour, session_id, meta), do: {:ok, new(flavour, session_id, meta, nil)}

  @doc false
  def resume(flavour, session_id, meta) do
    case Backend.meta_get(meta, key(flavour, "session_id")) do
      id when is_binary(id) -> {:ok, new(flavour, session_id, meta, id)}
      # Made, but restored before its first turn: nothing to resume yet.
      _ -> {:ok, new(flavour, session_id, meta, nil)}
    end
  end

  # The header's keys are the flavour's own: `grok_session_id`, `grok_model`, …
  defp key(flavour, what), do: String.to_atom("#{flavour.key()}_#{what}")

  defp new(flavour, loom_id, meta, agent_id) do
    %{
      flavour: flavour,
      loom_id: loom_id,
      session_id: agent_id,
      cwd:
        Backend.meta_get(meta, key(flavour, "cwd")) || Backend.meta_get(meta, :cc_cwd) ||
          default_cwd(),
      instructions: Backend.meta_get(meta, :instructions),
      model: Backend.meta_get(meta, key(flavour, "model")),
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
      # A conversation just made, no message in it yet; see `with_instructions/2`.
      fresh?: false,
      # Whether this turn has said it is running; see `announce/1`.
      announced?: false,
      tools: %{},
      interrupted?: false,
      context_tokens: 0,
      context_window: nil,
      # What the agent says the session is on (`currentModelId`), for `turn_done`.
      current_model: nil
    }
  end

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
  def warm(%{proc: proc} = handle) when proc != nil do
    if Proc.alive?(proc), do: {:ok, handle}, else: spawn_process(teardown(handle))
  end

  def warm(handle), do: spawn_process(handle)

  # ACP has no steering: the session queues the message.
  def steer(handle, _text), do: {:error, "#{handle.flavour.name()} cannot be steered mid-turn"}

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

  def persist(handle) do
    f = handle.flavour

    %{
      key(f, "session_id") => handle.session_id,
      key(f, "cwd") => handle.cwd,
      key(f, "model") => handle.model
    }
  end

  # In place on a warm process whose session is open, for a flavour that takes
  # `session/set_model`; before that it goes with the handshake. Back to the
  # default (nil) there is no call for, and a flavour that names its model when
  # spawned has none either: the process is let go of, and the next spawn
  # names the model, or none.
  def set_model(%{model: model} = handle, model), do: handle

  def set_model(%{proc: proc, session_id: sid, phase: phase} = handle, model)
      when is_binary(model) and model != "" and proc != nil and is_binary(sid) and
             phase in [:idle, :running] do
    if handle.flavour.model_in_place?(),
      do: select_model(%{handle | model: model}),
      else: %{teardown(handle) | model: model}
  end

  def set_model(%{phase: phase} = handle, model) when phase in [:init, :opening],
    do: %{handle | model: model}

  def set_model(handle, model), do: %{teardown(handle) | model: model}

  def release(%{proc: nil} = handle), do: {:ok, handle}
  def release(handle), do: {:ok, teardown(handle)}

  def relocate(handle, cwd, instructions) do
    {:ok, %{teardown(handle) | cwd: cwd || default_cwd(), instructions: instructions}}
  end

  def stop(handle) do
    teardown(handle)
    :ok
  end

  defp teardown(%{proc: nil} = handle), do: handle

  defp teardown(handle) do
    Proc.kill(handle.proc)
    %{handle | proc: nil, saved: nil, buffer: "", phase: :idle, pending: %{}, block: nil}
  end

  def detach(%{proc: nil}), do: :ok

  def detach(handle) do
    checkpoint(handle)
    Proc.close(handle.proc)
  end

  def adopt(handle) do
    case Proc.adopt(handle.loom_id) do
      {:ok, proc, saved} ->
        {:ok, %{Map.merge(handle, saved) | proc: proc, instructions: handle.instructions}}

      :error ->
        :error
    end
  end

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
         {:ok, exe} <- executable(handle.flavour) do
      File.mkdir_p!(handle.cwd)
      {exe, args} = sandboxed(handle, exe, handle.flavour.spawn_args(handle))

      with {:ok, proc} <- Proc.spawn(handle.loom_id, exe, args, handle.cwd) do
        init(%{handle | proc: proc, buffer: "", pending: %{}, phase: :init})
      end
    end
  end

  # A workstation's guard is a hook before every tool call, which ACP has none of.
  defp no_workstation(handle) do
    case Loom.Agent.Guard.rules(handle.loom_id) do
      %{"workstation" => ws} when ws not in [nil, ""] ->
        {:error,
         "a workstation needs Claude Code: #{handle.flavour.name()} runs no tool-call hooks"}

      _ ->
        :ok
    end
  end

  # The agent's own directory (login, conversations, logs) is written as it goes.
  defp sandboxed(%{sandbox: sandbox}, exe, args) when sandbox != true,
    do: Loom.Agent.Sandbox.guard_claude(exe, args)

  defp sandboxed(handle, exe, args) do
    Loom.Agent.Sandbox.wrap(
      true,
      exe,
      args,
      [handle.cwd, Loom.Agent.Store.output_dir(handle.loom_id)] ++
        Enum.map(handle.flavour.state_dirs(), &Path.expand/1) ++ Loom.Agent.Sandbox.caches()
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
  # What new and resume (or load) carry. Public for the tests.
  def session_params(handle),
    do: handle.flavour.session_params(handle, %{cwd: handle.cwd, mcpServers: []})

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

  # `/compact` and the agent's other commands are prompts that begin with a slash.
  defp prompt(%{prompt: text} = handle) do
    text = with_instructions(handle, text)
    handle = %{handle | phase: :running, prompt: nil, announced?: false, fresh?: false}
    params = %{sessionId: handle.session_id, prompt: [%{type: "text", text: text}]}
    send_rpc(handle, "session/prompt", params, :prompt)
  end

  # A flavour with no way to add to the system prompt gets the session's
  # instructions ahead of a new conversation's first message; from then on
  # they are in the conversation, a resumed one included.
  defp with_instructions(%{instructions: instructions} = handle, text)
       when is_binary(instructions) and instructions != "" do
    if Map.get(handle, :fresh?) == true and handle.flavour.instructions_in_prompt?() and
         not String.starts_with?(text, "/"),
       do: "<instructions>\n#{instructions}\n</instructions>\n\n#{text}",
       else: text
  end

  defp with_instructions(_handle, text), do: text

  defp select_model(%{model: model} = handle) when is_binary(model) and model != "" do
    if handle.flavour.model_in_place?() do
      params = %{sessionId: handle.session_id, modelId: model}

      handle
      |> send_rpc("session/set_model", params, :set_model)
      |> Map.put(:current_model, model)
    else
      # Named when it was spawned.
      %{handle | current_model: model}
    end
  end

  defp select_model(handle), do: handle

  # ── Decoding ────────────────────────────────────────────────────────────

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
          Logger.warning(
            "#{h.flavour.name()}: unparseable output line: #{String.slice(line, 0, 200)}"
          )

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
          %{
            reason:
              "#{handle.flavour.name()} exited with status #{status || "?"} before finishing the turn"
          }}
       ]}
  end

  # Asked of us. Permission should not come (every flavour is spawned to run
  # unasked); one that does is allowed once.
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
    Logger.warning("#{handle.flavour.name()}: unexpected request #{method}")

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
      # `session/load` replays the conversation as updates, which are not a
      # turn's and so are dropped (see `translate/2`): the phase is :opening.
      method = if handle.flavour.open() == :load, do: "session/load", else: "session/resume"
      {send_rpc(%{handle | phase: :opening}, method, params, :resume), []}
    else
      {send_rpc(%{handle | phase: :opening}, "session/new", params, :new), []}
    end
  end

  defp reply(handle, :new, %{"result" => %{"sessionId" => id} = result}) do
    opened(current_model(%{handle | session_id: id, fresh?: true}, result))
  end

  # `session/load` answers null.
  defp reply(handle, :resume, %{"result" => result}), do: opened(current_model(handle, result))

  # A conversation the agent no longer has: started afresh rather than failing every
  # turn after. The history shown stays; the agent's is gone.
  defp reply(handle, :resume, %{"error" => error}) do
    Logger.warning(
      "#{handle.flavour.name()}: cannot resume #{handle.session_id} (#{inspect(error)}); starting afresh"
    )

    handle = %{handle | session_id: nil}
    {send_rpc(handle, "session/new", session_params(handle), :new), []}
  end

  defp reply(handle, :prompt, %{"result" => result}) do
    out = close_block(handle)
    handle = last_context(%{handle | phase: :idle, block: nil}, result)

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
              usage: turn_usage(result["usage"] || get_in(result, ["_meta", "usage"])),
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
     out ++
       [{:event, :turn_failed, %{reason: "#{handle.flavour.name()}: " <> error_text(error)}}]}
  end

  defp reply(handle, :set_model, %{"error" => error}) do
    Logger.warning(
      "#{handle.flavour.name()}: cannot set the model #{inspect(handle.model)}: #{error_text(error)}"
    )

    {handle, []}
  end

  defp reply(handle, _what, _message), do: {handle, []}

  defp current_model(handle, %{"models" => %{"currentModelId" => model} = models})
       when is_binary(model) do
    # Grok sends no `usage_update`: the window is the model's, told here.
    window =
      Enum.find_value(List.wrap(models["availableModels"]), fn
        %{"modelId" => ^model, "_meta" => %{"totalContextTokens" => n}} when is_integer(n) -> n
        _ -> nil
      end)

    %{handle | current_model: model, context_window: window || handle.context_window}
  end

  defp current_model(handle, _result), do: handle

  # Grok: what the turn's last model call held is how full the context is.
  defp last_context(handle, %{"_meta" => %{"totalTokens" => n}}) when is_integer(n) and n > 0,
    do: %{handle | context_tokens: n}

  defp last_context(handle, _result), do: handle

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
      "cache_creation_input_tokens" => u["cachedWriteTokens"] || u["cacheCreationTokens"] || 0
    }
  end

  defp turn_usage(_), do: %{}

  # ── This turn's updates ──────────────────────────────────────────────────

  defp update(handle, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :text, text)

  defp update(handle, %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => text}}),
       do: chunk(handle, :thinking, text)

  # Told once per call, already under way; a second telling is not a new call.
  # CodeBuddy tells a call before the model has written its arguments (an
  # empty `rawInput`), streams them, then tells it again complete: such a call
  # waits, and is shown when its arguments are whole, or with its result.
  defp update(handle, %{"sessionUpdate" => "tool_call", "toolCallId" => id} = u)
       when not is_map_key(handle.tools, id) do
    if tool_args(u) == %{} and u["status"] not in ["completed", "failed"],
      do: {%{handle | tools: Map.put(handle.tools, id, {:waiting, u})}, []},
      else: tool_start(handle, id, u)
  end

  defp update(handle, %{"sessionUpdate" => kind, "toolCallId" => id} = u)
       when kind in ["tool_call", "tool_call_update"] do
    case {Map.get(handle.tools, id), u["status"]} do
      {{:waiting, first}, status} when kind == "tool_call" or status in ["completed", "failed"] ->
        {handle, out} = tool_start(handle, id, Map.merge(first, u))
        {handle, out ++ tool_end(handle, id, u)}

      # Its arguments, as far as they are written.
      {{:waiting, first}, _} ->
        {%{handle | tools: Map.put(handle.tools, id, {:waiting, Map.merge(first, u)})}, []}

      _ ->
        {handle, tool_end(handle, id, u)}
    end
  end

  defp update(handle, _update), do: {handle, []}

  defp tool_start(handle, id, u) do
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

  defp tool_end(handle, id, %{"status" => status} = u) when status in ["completed", "failed"] do
    [
      {:event, :tool_result,
       %{
         id: id,
         name: Map.get(handle.tools, id, "tool"),
         status: if(status == "failed", do: :error, else: :ok),
         output: tool_output(u)
       }}
    ]
  end

  defp tool_end(_handle, _id, _update), do: []

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

  # `kind` is the tool (`execute`, `read`, `edit`…); `name` is the agent's own
  # (`run_command`), `title` what it does now.
  defp tool_name(u) do
    # Grok tells the kind in its own `_meta` until the call's first update.
    case u["kind"] || get_in(u, ["_meta", "x.ai/tool", "kind"]) do
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
  defp tool_args(u) do
    case u["rawInput"] || u["args"] do
      %{} = input -> input
      _ -> %{}
    end
  end

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
      {_, %{"text" => text}} when is_binary(text) -> text
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

  @doc "The flavour's CLI, by its configured name or its usual ones; nil when not installed."
  def find_executable(flavour) do
    Enum.find_value(flavour.executables(), fn name ->
      System.find_executable(name) || System.find_executable(Path.expand("~/.local/bin/" <> name))
    end)
  end

  defp executable(flavour) do
    case find_executable(flavour) do
      nil -> {:error, "could not find `#{hd(flavour.executables())}` on PATH"}
      path -> {:ok, path}
    end
  end

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end
end
