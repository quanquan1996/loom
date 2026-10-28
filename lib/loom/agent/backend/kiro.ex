defmodule Loom.Agent.Backend.Kiro do
  @moduledoc """
  Kiro CLI over the Agent Client Protocol: `kiro-cli-chat acp`, JSON-RPC on
  stdio, one process per session — Claude Code's model (see `ClaudeCode`):
  spawned on the first turn, kept warm between turns, killed by `release/1`.
  Measured on kiro-cli 1.28.1.

  ## A spawn is a handshake, then the turn

  `initialize`, then `session/new` (the first time; the reply names the
  conversation) or `session/load` (every time after, by that id), and only then
  `session/prompt`. All of it asynchronous: `run_turn/2` writes `initialize` and
  returns, and `decode/2` walks the rest as the replies come. The prompt waits
  in the handle until the session is there.

  `session/load` replays the whole conversation as `session/update`s before it
  answers. Those are history, not this turn, and are dropped.

  ## The system prompt is an agent

  ACP has no system prompt. A Kiro *agent* has one (`prompt`), so each session
  gets its own, `~/.kiro/agents/loom-<session>.json` with every tool, written
  before every spawn and named with `--agent`. Unlike Claude Code's, it is read
  again on each spawn, so changed instructions reach a conversation already
  under way.

  ## Killing is a process group

  `kiro-cli` is a launcher for `kiro-cli-chat`; the launcher killed, the child
  lives on and holds the conversation's lock ("Session is active in another
  process"), so the next `session/load` fails. The child is spawned directly,
  and killed with its descendants (`ClaudeCode.kill_tree/1`).

  ## No steering, no cost

  ACP has one prompt at a time per session, so `steer/2` refuses and the
  session queues the message for after the turn. Kiro reports no cost, only
  how full the context is (`_kiro.dev/metadata`, a percentage), which becomes
  `context_tokens` against the model's window.
  """
  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Backend.ClaudeCode
  alias Loom.Agent.Jsonl

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
      port: nil,
      os_pid: nil,
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
      context_tokens: 0
    }
  end

  @impl Backend
  def run_turn(handle, text) when is_binary(text) do
    handle = %{handle | prompt: text, interrupted?: false, tools: %{}, block: nil}

    cond do
      handle.port && Port.info(handle.port) && handle.phase == :idle -> {:ok, prompt(handle)}
      handle.port && Port.info(handle.port) -> {:ok, handle}
      true -> spawn_process(handle)
    end
  end

  @impl Backend
  def steer(_handle, _text), do: {:error, "kiro takes one prompt at a time"}

  @impl Backend
  def interrupt(%{port: nil} = handle), do: {:ok, handle}

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

  @impl Backend
  def release(%{port: nil} = handle), do: {:ok, handle}
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

  defp teardown(%{port: nil} = handle), do: handle

  defp teardown(handle) do
    ClaudeCode.kill_tree(handle.os_pid)
    if Port.info(handle.port), do: Port.close(handle.port)
    %{handle | port: nil, os_pid: nil, buffer: "", phase: :idle, pending: %{}, block: nil}
  end

  # ── Spawning ────────────────────────────────────────────────────────────

  defp spawn_process(handle) do
    with {:ok, exe} <- executable(),
         :ok <- write_agent(handle) do
      File.mkdir_p!(handle.cwd)

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: ["acp", "--trust-all-tools", "--agent", agent_name(handle)],
          cd: handle.cwd,
          env: Loom.ChildEnv.port_env()
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      handle = %{handle | port: port, os_pid: os_pid, buffer: "", pending: %{}, phase: :init}

      params = %{
        protocolVersion: 1,
        clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}, terminal: false},
        clientInfo: %{name: "loom", version: "1"}
      }

      {:ok, send_rpc(handle, "initialize", params, :initialize)}
    end
  end

  @doc false
  def agent_name(handle), do: "loom-" <> handle.loom_id

  @doc "Where a session's agent (its system prompt) is kept."
  def agent_path(loom_id), do: Path.join([kiro_dir(), "agents", "loom-#{loom_id}.json"])

  defp write_agent(handle) do
    agent = %{
      name: agent_name(handle),
      description: "A Loom session (#{handle.loom_id}); written by Loom before every start.",
      prompt: handle.instructions,
      tools: ["*"],
      allowedTools: ["*"],
      includeMcpJson: true,
      model: handle.model
    }

    path = agent_path(handle.loom_id)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(agent, pretty: true))
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
    try do
      Port.command(handle.port, Jsonl.line(message))
    rescue
      ArgumentError -> :closed
    end

    handle
  end

  defp prompt(handle) do
    params = %{sessionId: handle.session_id, prompt: [%{type: "text", text: handle.prompt}]}

    send_rpc(
      %{handle | phase: :running, prompt: nil, announced?: false},
      "session/prompt",
      params,
      :prompt
    )
  end

  # ── Decoding ────────────────────────────────────────────────────────────

  @impl Backend
  def decode(%{port: port} = handle, {port, {:data, chunk}}) do
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

    {:ok, handle, out}
  end

  def decode(%{port: port} = handle, {port, {:exit_status, status}}) do
    {:ok, %{handle | port: nil, os_pid: nil, phase: :idle, pending: %{}},
     close_block(handle) ++
       [
         {:event, :turn_failed,
          %{reason: "kiro exited with status #{status} before finishing the turn"}}
       ]}
  end

  # One we killed, confirming it died.
  def decode(handle, {port, {:exit_status, _}}) when is_port(port), do: {:ok, handle, []}

  def decode(_handle, _message), do: :ignore

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

  # Asked of us: permission (never, under --trust-all-tools), files, terminals
  # (refused at `initialize`). Answered so the agent does not wait.
  defp translate(handle, %{"id" => id, "method" => method}) do
    Logger.warning("Kiro: unexpected request #{method}")

    {write(handle, %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "not supported"}}),
     []}
  end

  defp translate(handle, _message), do: {handle, []}

  defp reply(handle, :initialize, %{"result" => _}) do
    if handle.session_id do
      params = %{sessionId: handle.session_id, cwd: handle.cwd, mcpServers: []}
      {send_rpc(%{handle | phase: :opening}, "session/load", params, :load), []}
    else
      params = %{cwd: handle.cwd, mcpServers: []}
      {send_rpc(%{handle | phase: :opening}, "session/new", params, :new), []}
    end
  end

  defp reply(handle, :new, %{"result" => %{"sessionId" => id}}) do
    opened(%{handle | session_id: id})
  end

  defp reply(handle, :load, %{"result" => _}), do: opened(handle)

  # A conversation Kiro no longer has: started afresh rather than failing every
  # turn after. The history shown stays; the agent's is gone.
  defp reply(handle, :load, %{"error" => error}) do
    Logger.warning("Kiro: cannot load #{handle.session_id} (#{inspect(error)}); starting afresh")
    params = %{cwd: handle.cwd, mcpServers: []}
    {send_rpc(%{handle | session_id: nil}, "session/new", params, :new), []}
  end

  defp reply(handle, :prompt, %{"result" => result}) do
    out = close_block(handle)
    handle = %{handle | phase: :idle, block: nil}

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
                context_window: @window
              }}
           ]}
    end
  end

  defp reply(handle, what, %{"error" => error}) when what in [:initialize, :new, :prompt] do
    out = close_block(handle)

    {%{handle | phase: :idle, block: nil},
     out ++ [{:event, :turn_failed, %{reason: "kiro: " <> error_text(error)}}]}
  end

  defp reply(handle, _what, _message), do: {handle, []}

  # The session is there; the turn begins.
  defp opened(handle) do
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

  defp tool_output(u) do
    case u["rawOutput"] do
      %{"items" => items} when is_list(items) -> Enum.map_join(items, "\n", &item_text/1)
      nil -> content_text(u["content"])
      other -> Jason.encode!(other)
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
    configured = Application.get_env(:loom, Loom.Agent, [])[:kiro_cli] || "kiro-cli-chat"

    case System.find_executable(configured) ||
           System.find_executable(Path.expand("~/.local/bin/" <> configured)) do
      nil -> {:error, "could not find the `#{configured}` executable on PATH"}
      path -> {:ok, path}
    end
  end

  defp kiro_dir, do: Path.expand("~/.kiro")

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end
end
