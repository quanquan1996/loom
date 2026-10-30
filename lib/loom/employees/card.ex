defmodule Loom.Employees.Card do
  @moduledoc """
  The work card a virtual employee ends a turn with: a fenced block,

      ```employee-card
      {"next": "sleep", "wake_at": "2026-10-29 09:00", "summary": "…",
       "kpis": [{"id": "k_…", "progress": 40, "status": "doing", "note": "…"}],
       "report": {"priority": 4, "text": "…", "key": "…", "needs": "read"},
       "withdraw": ["a key"], "boss": ["a line for the boss profile"]}
      ```

  in its last message. The last such block wins; one that isn't JSON, or isn't
  there, is an empty card, which `Loom.Employees` reads as "sleep until the
  heartbeat". Its fields are documented to the agent in
  `Loom.Employees.Prompt`.
  """

  @fence ~r/```employee-card[ \t]*\n(.*?)\n?```/s

  @doc "The card in `text`, or `%{}`."
  def parse(text) when is_binary(text) do
    with [_ | _] = blocks <- Regex.scan(@fence, text),
         [_, body] <- List.last(blocks),
         {:ok, %{} = card} <- Jason.decode(body) do
      clean(card)
    else
      _ -> %{}
    end
  end

  def parse(_), do: %{}

  # Only what is shaped right is kept, so the rest of Loom can trust it.
  defp clean(card) do
    card
    |> keep("next", &(&1 in ["sleep", "continue"]))
    |> keep("wake_at", &is_binary/1)
    |> keep("sleep_minutes", &(is_number(&1) and &1 > 0))
    |> keep("summary", &is_binary/1)
    |> keep("kpis", &is_list/1)
    |> keep("kpi_add", &is_list/1)
    |> keep("wake_now", &is_boolean/1)
    |> keep("note_for_work", &is_binary/1)
    |> keep("report", fn r ->
      is_map(r) and is_binary(r["text"]) and
        (r["level"] in ["info", "important", "urgent"] or
           (is_integer(r["priority"]) and r["priority"] in 0..10))
    end)
    |> keep("withdraw", &(is_list(&1) and Enum.all?(&1, fn k -> is_binary(k) end)))
    |> keep("boss", &is_list/1)
    |> Map.take(
      ~w(next wake_at sleep_minutes summary kpis kpi_add wake_now note_for_work report withdraw boss)
    )
  end

  defp keep(card, key, ok?) do
    case Map.fetch(card, key) do
      {:ok, v} -> if ok?.(v), do: card, else: Map.delete(card, key)
      :error -> card
    end
  end

  @doc """
  A wall-clock time, `YYYY-MM-DD HH:MM` (or with a `T`), read in the user's
  time zone `offset` (minutes east of UTC): milliseconds, or nil.
  """
  def local_time(text, offset) when is_binary(text) do
    with [_, date, h, m] <- Regex.run(~r/^(\d{4}-\d{2}-\d{2})[ T](\d{1,2}):(\d{2})/, text),
         {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.new(String.to_integer(h), String.to_integer(m), 0),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      (naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)) -
        offset * 60_000
    else
      _ -> nil
    end
  end

  def local_time(_text, _offset), do: nil
end
