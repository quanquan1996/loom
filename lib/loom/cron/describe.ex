defmodule Loom.Cron.Describe do
  @moduledoc """
  A task as the user says it — "every Monday at nine, an AWS industry report"
  — read into what `Loom.Cron` keeps: a short name, the prompt to send each
  time, and a five-field cron expression in the user's own time. What the
  Tasks page's composer does; a `Loom.OneShot`.

  The model's answer is only a proposal: the expression is parsed like any
  other, and one that is missing or does not parse is refused with a sentence
  that says what to add.
  """

  alias Loom.Cron.Expr

  @text_limit 2000

  @doc """
  `{:ok, %{name:, prompt:, cron:}}` or `{:error, sentence}`. `now` is the
  user's wall-clock time, so "tomorrow" and "every morning" mean theirs.
  """
  def describe(text, %NaiveDateTime{} = now, ask \\ asker()) do
    text = String.trim(to_string(text))

    if text == "" do
      {:error, "say what to do, and when"}
    else
      case ask.(system(now), String.slice(text, 0, @text_limit)) do
        {:ok, reply} -> read(reply)
        {:error, _} -> {:error, "could not read that just now; try again, or fill it in by hand"}
      end
    end
  end

  # A test puts a stand-in here rather than call the real `claude`.
  defp asker, do: Application.get_env(:loom, __MODULE__, [])[:ask] || (&Loom.OneShot.ask/2)

  @doc false
  # Public for the tests: everything that can come back.
  def read(reply) do
    with {:ok, json} <- json(reply),
         %{"prompt" => prompt} when is_binary(prompt) and prompt != "" <- json,
         {:ok, cron} <- cron(json["cron"]) do
      {:ok, %{name: name(json["name"], prompt), prompt: String.trim(prompt), cron: cron}}
    else
      {:error, sentence} -> {:error, sentence}
      _ -> {:error, "say what to do, and when"}
    end
  end

  # The model may wrap it in a fence, or a sentence; the object is what counts.
  defp json(reply) do
    case Regex.run(~r/\{.*\}/s, reply) do
      [object] ->
        case Jason.decode(object) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp cron(cron) when is_binary(cron) do
    cron = cron |> String.split() |> Enum.join(" ")

    case Expr.parse(cron) do
      {:ok, _} -> {:ok, cron}
      {:error, _} -> {:error, "say when it should run — every day at 9, every Monday morning…"}
    end
  end

  defp cron(_none), do: {:error, "say when it should run — every day at 9, every Monday morning…"}

  defp name(name, _prompt) when is_binary(name) and name != "", do: String.slice(name, 0, 60)
  defp name(_none, prompt), do: prompt |> String.split("\n") |> hd() |> String.slice(0, 40)

  defp system(now) do
    day = Calendar.strftime(now, "%A")

    """
    You turn a user's request for a recurring task into JSON for a scheduler. \
    The user's local time is now #{NaiveDateTime.to_string(now) |> String.slice(0, 16)} (#{day}).

    Reply with only one JSON object, nothing else:
    {"name": "...", "prompt": "...", "cron": "..."}

    - name: a short title for the task, in the user's language, at most 30 characters.
    - prompt: what the assistant should be asked to do each time it runs, as a \
    request to the assistant, in the user's language, keeping every detail the \
    user gave about content and format, and leaving out the schedule.
    - cron: a standard five-field cron expression (minute hour day-of-month \
    month day-of-week) in the user's local time. "Every morning" is 9:00, \
    "every evening" 18:00, "weekdays" 1-5. If the request says nothing about \
    when, use null.

    Do not carry out the task.
    """
  end
end
