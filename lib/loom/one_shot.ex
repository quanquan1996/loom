defmodule Loom.OneShot do
  @moduledoc """
  The model calls Loom makes of its own, rather than through a session: a
  one-shot `claude -p` on the smallest model, with no tools, no MCP servers, no
  settings or memory and nothing persisted. About two seconds and a fifth of a
  cent (measured).

  Used to file a new session into a project (`Loom.Projects.Classifier`) and
  to read a task the user described in words (`Loom.Cron.Describe`).
  """

  @doc "The model's reply to `text` under `system`: `{:ok, reply}` or `{:error, reason}`."
  def ask(system, text) do
    with {:ok, exe} <- executable(),
         {out, 0} <- System.cmd(exe, args(system, text), cd: System.tmp_dir!(), env: env()),
         {:ok, %{"result" => reply}} when is_binary(reply) <- Jason.decode(out) do
      {:ok, reply}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  end

  defp args(system, text) do
    [
      "-p",
      "--model",
      "haiku",
      "--no-session-persistence",
      "--tools",
      "",
      "--strict-mcp-config",
      "--setting-sources",
      "",
      "--output-format",
      "json",
      "--system-prompt",
      system,
      text
    ]
  end

  defp executable do
    configured = Application.get_env(:loom, Loom.Agent, [])[:claude_cli] || "claude"

    case System.find_executable(configured) do
      nil -> {:error, :no_claude}
      path -> {:ok, path}
    end
  end

  # What every child gets (`Loom.ChildEnv`), with loom's own variables unset
  # rather than merely left out: `System.cmd` adds to the environment.
  defp env do
    keep = Loom.ChildEnv.map()
    drop = for {key, _} <- System.get_env(), not Map.has_key?(keep, key), do: {key, nil}
    Enum.to_list(keep) ++ drop
  end
end
