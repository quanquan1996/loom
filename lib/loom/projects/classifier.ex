defmodule Loom.Projects.Classifier do
  @moduledoc """
  Which of the user's projects a new session's first message belongs to, if
  any.

  A `Loom.OneShot`, told the projects and asked for one id or `NONE`. About
  two seconds, which is why it runs *before* the first turn rather than after
  it: the session then starts in the project's workspace with its
  instructions in the system prompt, as if it had been made there. See
  `Loom.Agent.Session`.

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
    case Loom.OneShot.ask(prompt(projects), String.slice(text, 0, @message_shown)) do
      {:ok, answer} ->
        pick(answer, projects)

      {:error, reason} ->
        Logger.warning(
          "Loom.Projects.Classifier: no answer (#{inspect(reason) |> String.slice(0, 200)})"
        )

        nil
    end
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
end
