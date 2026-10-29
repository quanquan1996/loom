defmodule Loom.Agent.Search do
  @moduledoc """
  Find the sessions whose conversation mentions some words: what the user
  wrote and what the agent answered, not its thinking or its tools.

  A scan of every transcript, on each query. They are a few megabytes in all,
  so an index would be a second copy to keep in step for nothing; a line is
  only decoded once its raw JSON already contains the words.
  """

  alias Loom.Agent.Store

  @kinds ["user", "assistant_text"]

  # Around the first match: enough before it to read it in context, and the
  # rest of a line's worth after.
  @lead 24
  @trail 80

  @limit 50

  @doc """
  Each session that mentions `query` (any case), newest match first, as
  `%{id:, snippet:, seq:}` — the first match's text around it, and its event.
  """
  def run(ids, query) when is_list(ids) and is_binary(query) do
    query = String.trim(query)

    if query == "" do
      []
    else
      re = Regex.compile!(Regex.escape(query), "iu")
      # The raw line has `"` and `\\` escaped; a query with them is checked on
      # the decoded text only.
      raw? = not String.contains?(query, ["\"", "\\"])

      ids
      |> Task.async_stream(&in_session(&1, re, raw?), ordered: false, timeout: 10_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, hit} -> [hit]
        _ -> []
      end)
      |> Enum.sort_by(& &1.at, :desc)
      |> Enum.take(@limit)
    end
  end

  defp in_session(id, re, raw?) do
    case File.read(Store.events_path(id)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(&in_line(&1, id, re, raw?))

      _ ->
        nil
    end
  end

  defp in_line(line, id, re, raw?) do
    with true <- not raw? or Regex.match?(re, line),
         {:ok, %{"kind" => kind, "payload" => %{"text" => text}} = event} when kind in @kinds and is_binary(text) <-
           Jason.decode(line),
         text = plain(text),
         [{start, len} | _] <- Regex.run(re, text, return: :index) do
      %{id: id, seq: event["seq"], at: event["at"], snippet: snippet(text, start, len)}
    else
      _ -> nil
    end
  end

  # Read as a line of text, not Markdown: no emphasis marks, headings, code
  # ticks or table rules.
  defp plain(text) do
    text
    |> String.replace(~r/\|?(\s*:?-{3,}:?\s*\|)+/u, " ")
    |> String.replace(~r/[*#`>|]+/u, " ")
  end

  defp snippet(text, start, len) do
    before = text |> binary_part(0, start) |> String.graphemes()
    rest = text |> binary_part(start + len, byte_size(text) - start - len) |> String.graphemes()
    lead = if length(before) > @lead, do: "…", else: ""
    tail = if length(rest) > @trail, do: "…", else: ""

    (lead <>
       Enum.join(Enum.take(before, -@lead)) <>
       binary_part(text, start, len) <> Enum.join(Enum.take(rest, @trail)) <> tail)
    |> String.replace(~r/\s+/u, " ")
  end
end
