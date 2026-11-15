defmodule Loom.Agent.Search do
  @moduledoc """
  Find the sessions whose title or conversation has some words: what the user
  wrote and what the agent answered, not its thinking or its tools.

  A query is words split on spaces; a session has them all when each is in
  its title or somewhere in what was said — not necessarily in one message.

  A scan of every transcript, on each query. An index would be a second copy
  to keep in step; a line is only decoded once its raw JSON already has one
  of the words.

  `ranked/2` is the sidebar's search, in two tiers: first what the sidebar
  lists (Pinned, Working, Recents — the user's own chats, not archived), then
  the rest: archived ones, and employees', notices', tasks' and dreams'.
  """

  alias Loom.Agent.Store

  @kinds ["user", "assistant_text"]

  # A user message the user typed or tapped (a bell reply comes as "notice"),
  # not one Loom wrote for an employee's wake-up, a cron job or a dream.
  @own_origins ["desktop", "phone", "notice"]

  # Within a tier, how long ago it was used, by these steps — before where
  # the words are, after the kind of session.
  @day 24 * 3600 * 1000
  @age_steps [@day, 3 * @day, 7 * @day]

  # Around the first match: enough before it to read it in context, and the
  # rest of a line's worth after.
  @lead 24
  @trail 80

  @limit 50

  @doc """
  The sidebar's search over `infos` (session infos with `:id`, `:title`,
  `:kind`, `:last_active_at`, `:archived_at`): each that has all the words,
  as `%{id:, tier:, match:, snippet:, seq:, at:}` in the order to show them.

  `tier` 1 is a session the sidebar lists (`Store.own_chat?/1`, not
  archived); 2 is the rest. Each tier is ordered by the kind of session
  (plain chats, then chats with an employee, then the rest), then by how
  recently it was used (today, three days, a week, older), then by where the
  words are (`match`: "title", "mine" — what the user wrote — or "said"),
  then newest. Up to fifty of each.
  """
  def ranked(infos, query, now \\ System.system_time(:millisecond)) when is_list(infos) and is_binary(query) do
    case words(query) do
      [] ->
        []

      words ->
        res = regexes(words)

        infos
        |> Task.async_stream(&hit(&1, words, res, now), ordered: false, timeout: 10_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, nil} -> []
          {:ok, hit} -> [hit]
          _ -> []
        end)
        |> Enum.group_by(& &1.tier)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {_, hits} -> hits |> Enum.sort_by(& &1.order) |> Enum.take(@limit) end)
        |> Enum.map(&Map.drop(&1, [:order]))
    end
  end

  @doc """
  Each session of `ids` whose conversation has all the words of `query` (any
  case), newest match first, as `%{id:, snippet:, seq:, at:}` — the newest
  message with the most of them, around the first.
  """
  def run(ids, query) when is_list(ids) and is_binary(query) do
    case words(query) do
      [] ->
        []

      words ->
        res = regexes(words)

        ids
        |> Task.async_stream(&{&1, scan(&1, res)}, ordered: false, timeout: 10_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, {id, %{said: said, best: best}}} when best != nil ->
            if MapSet.size(said) == length(words), do: [Map.put(best, :id, id)], else: []

          _ ->
            []
        end)
        |> Enum.sort_by(& &1.at, :desc)
        |> Enum.take(@limit)
    end
  end

  defp words(query), do: query |> String.split(~r/\s+/u, trim: true) |> Enum.uniq_by(&String.downcase/1)

  # Each word's regex, and whether its raw JSON line can be checked for it —
  # the raw line has `"` and `\\` escaped, so a word with them is checked on
  # the decoded text only.
  defp regexes(words) do
    Enum.with_index(words, fn word, i ->
      {i, Regex.compile!(Regex.escape(word), "iu"), not String.contains?(word, ["\"", "\\"])}
    end)
  end

  defp hit(info, words, res, now) do
    n = length(words)
    title = info[:title] || ""
    in_title = for {i, re, _} <- res, Regex.match?(re, title), into: MapSet.new(), do: i
    # Every word the title lacks must at least be in the raw transcript.
    rest = Enum.reject(res, fn {i, _, _} -> MapSet.member?(in_title, i) end)

    with %{said: said, mine: mine, best: best} <- scan(info.id, rest),
         true <- MapSet.size(MapSet.union(in_title, said)) == n do
      at = info[:last_active_at] || info[:created_at] || 0
      age = now - at

      match =
        cond do
          MapSet.size(in_title) == n -> "title"
          MapSet.size(MapSet.union(in_title, mine)) == n -> "mine"
          true -> "said"
        end

      tier = if listed?(info), do: 1, else: 2
      # Words only in the title: the newest line with some of them, if any.
      best = best || %{seq: nil, at: nil, snippet: nil}

      %{
        id: info.id,
        tier: tier,
        match: match,
        snippet: best.snippet,
        seq: best.seq,
        at: at,
        order: {kind_rank(info[:kind]), age_step(age), match_rank(match), -at}
      }
    else
      _ -> nil
    end
  end

  # In the sidebar's lists: the user's own chat, not archived since last used.
  defp listed?(info) do
    at = info[:archived_at]
    Store.own_chat?(info) and not (is_integer(at) and (info[:last_active_at] || 0) <= at)
  end

  defp kind_rank(nil), do: 0
  defp kind_rank(kind) when kind in ["employee_chat", "employee_setup"], do: 1
  defp kind_rank(_), do: 2

  defp age_step(age), do: Enum.find_index(@age_steps, &(age < &1)) || length(@age_steps)

  defp match_rank("title"), do: 0
  defp match_rank("mine"), do: 1
  defp match_rank("said"), do: 2

  # What one transcript has: which words were said (by anyone), which the
  # user wrote, and the newest message with the most of the words. nil when it has no transcript, or lacks a
  # word outright.
  defp scan(id, res) do
    with {:ok, body} <- File.read(Store.events_path(id)),
         true <- Enum.all?(res, fn {_, re, raw?} -> not raw? or Regex.match?(re, body) end) do
      acc = %{said: MapSet.new(), mine: MapSet.new(), best: nil, best_n: 0}

      if res == [] do
        acc
      else
        body
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.reduce(acc, &line(&1, res, &2))
      end
    else
      _ -> nil
    end
  end

  defp line(raw, res, acc) do
    with true <- Enum.any?(res, fn {_, re, raw?} -> not raw? or Regex.match?(re, raw) end),
         {:ok, %{"kind" => kind, "payload" => %{"text" => text} = payload} = event}
         when kind in @kinds and is_binary(text) <- Jason.decode(raw) do
      text = plain(text)
      found = for {i, re, _} <- res, Regex.match?(re, text), do: i

      if found == [] do
        acc
      else
        mine? = kind == "user" and payload["origin"] in @own_origins
        acc = %{acc | said: MapSet.union(acc.said, MapSet.new(found))}
        acc = if mine?, do: %{acc | mine: MapSet.union(acc.mine, MapSet.new(found))}, else: acc

        # Lines come newest first: a later one replaces it only with more words.
        if length(found) > acc.best_n do
          {_, re, _} = Enum.find(res, fn {i, _, _} -> i == hd(found) end)
          [{start, len} | _] = Regex.run(re, text, return: :index)
          %{acc | best: %{seq: event["seq"], at: event["at"], snippet: snippet(text, start, len)}, best_n: length(found)}
        else
          acc
        end
      end
    else
      _ -> acc
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
