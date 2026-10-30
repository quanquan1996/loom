defmodule Loom.Agent.Guard do
  @moduledoc """
  Rules a session's tool calls are checked against before they run, for the
  virtual employees given a workstation (`Loom.Employees`). A session has
  rules when `~/.loom/guards/<id>.json` exists; its backend then installs
  `loom-guard` (`rel/loom-guard`) as the hook that runs before every tool —
  Claude Code's `PreToolUse` through `--settings`, Kiro's `preToolUse` in its
  agent — at each spawn. The hook reads the file at every call, so the rules
  can change under a running process; without a workstation in them it lets
  everything through.
  """

  alias Loom.Agent.Store

  def dir, do: Path.join(Store.home(), "guards")
  def path(session_id), do: Path.join(dir(), "#{session_id}.json")

  def guarded?(session_id), do: is_binary(session_id) and File.exists?(path(session_id))

  @doc """
  The hook's command, as installed by `rel/deploy.sh`, told where the rules
  are: an agent's environment does not carry Loom's home.
  """
  def command do
    exe =
      Application.get_env(:loom, __MODULE__, [])[:command] ||
        Path.expand("~/.local/bin/loom-guard")

    "#{exe} #{dir()}"
  end

  @doc "Write a session's rules (a map), or with nil take them away."
  def put(session_id, nil), do: File.rm(path(session_id))

  def put(session_id, rules) do
    File.mkdir_p!(dir())
    tmp = path(session_id) <> ".tmp"
    File.write!(tmp, Jason.encode!(rules, pretty: true))
    File.rename!(tmp, path(session_id))
  end

  @doc "Claude Code's `--settings`, with the hook."
  def claude_settings do
    Jason.encode!(%{
      hooks: %{"PreToolUse" => [%{matcher: "", hooks: [%{type: "command", command: command()}]}]}
    })
  end

  @doc "A Kiro agent's `hooks`."
  def kiro_hooks, do: %{"preToolUse" => [%{matcher: "*", command: command()}]}
end
