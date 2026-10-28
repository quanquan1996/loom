defmodule Loom.Projects.Classifier do
  @moduledoc """
  Which of the user's projects a new session's first message belongs to, if
  any: the one model call Loom makes of its own.

  A one-shot `claude -p` on the smallest model, with no tools, no MCP servers,
  no settings or memory and nothing persisted, told the projects and asked for
  one id or `NONE`. About two seconds and a fifth of a cent (measured), which is
  why it runs *before* the first turn rather than after it: the session then
  starts in the project's workspace with its instructions in the system
  prompt, as if it had been made there. See `Loom.Agent.Session`.

  Anything that goes wrong — no `claude`, a timeout, an answer that is not one
  of the ids — is "no project": a session left where the user made it.
  """

  require Logger

  # Enough of each project to tell them apart.
  @instructions_shown 300
  @message_shown 2000

  @doc "A project id from `projects`, or nil."
  def classify(_text, []), do: nil

  def classify(text, projects) do
    with {:ok, exe} <- executable(),
         {out, 0} <- System.cmd(exe, args(text, projects), cd: System.tmp_dir!(), env: env()),
         {:ok, %{"result" => answer}} <- Jason.decode(out) do
      pick(answer, projects)
    else
      other ->
        Logger.warning(
          "Loom.Projects.Classifier: no answer (#{inspect(other) |> String.slice(0, 200)})"
        )

        nil
    end
  rescue
    error ->
      Logger.warning("Loom.Projects.Classifier failed: #{inspect(error)}")
      nil
  end

  @doc false
  # Public for the tests: the answer is the model's, so only an id it was given
  # counts, whatever else it wrote around it.
  def pick(answer, projects) when is_binary(answer) do
    ids = Enum.map(projects, & &1.id)

    case Regex.scan(~r/p_[A-Za-z0-9_-]+/, answer)
         |> List.flatten()
         |> Enum.filter(&(&1 in ids))
         |> Enum.uniq() do
      [id] -> id
      _ -> nil
    end
  end

  def pick(_answer, _projects), do: nil

  defp args(text, projects) do
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
      prompt(projects),
      String.slice(text, 0, @message_shown)
    ]
  end

  defp prompt(projects) do
    listed =
      Enum.map_join(projects, "\n", fn p ->
        about =
          p.instructions
          |> to_string()
          |> String.replace(~r/\s+/, " ")
          |> String.slice(0, @instructions_shown)

        "#{p.id}: #{p.name}" <> if(about == "", do: "", else: " — #{about}")
      end)

    """
    You file a new conversation into one of the user's projects. The user's \
    first message follows. Reply with only the id of the one project it clearly \
    belongs to, or NONE if it does not clearly belong to any. Do not answer the \
    message itself.

    Projects:
    #{listed}
    """
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
