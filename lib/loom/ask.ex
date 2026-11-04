defmodule Loom.Ask do
  @moduledoc """
  One question in, one spoken answer out — for a voice shortcut such as an
  iPhone Shortcut run by Siri ("Hey Siri, <shortcut name>").

  Every question goes to one standing session titled "Siri", so a follow-up
  can lean on the last answer and the whole exchange can be read in Loom
  afterwards. A session a safety classifier stopped is left behind and a
  fresh one started, as the other fixed jobs do (`Loom.Agent.flagged?/1`).

  The caller waits up to `@wait` for the turn to end: a proxy in front of Loom
  usually cuts a request off at 60 s. A turn still running then carries on;
  the caller is told so and its answer stays in the session.
  """

  alias Loom.Agent

  @wait 50_000

  @voice """
  [Note from Loom, not written by the user: this came by voice through Siri on \
  the user's phone, and your reply will be read aloud. Answer in one to three \
  short spoken sentences, in the user's language — no Markdown, lists, code, \
  links or suggested-reply block. Do what is asked first if it is a task, then \
  say the result.]

  """

  @doc "Ask; `{:ok, text}`, `:pending` when the turn outlasts the wait, or `{:error, reason}`."
  def ask(text, wait \\ @wait) when is_binary(text) do
    with {:ok, id} <- session() do
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.turns_topic())

      try do
        case Agent.submit(id, text, origin: "siri", prompt: @voice <> text) do
          {:ok, _} -> await(id, wait)
          {:error, reason} -> {:error, reason}
        end
      after
        Phoenix.PubSub.unsubscribe(Loom.PubSub, Agent.turns_topic())
      end
    end
  end

  defp await(id, wait) do
    receive do
      {:turn_ended, ^id, %{outcome: {:ok, text}}} -> {:ok, speakable(text)}
      {:turn_ended, ^id, %{outcome: {:error, message}}} -> {:error, message}
    after
      wait -> :pending
    end
  end

  # What a speaker can read: no reply-button block, no Markdown marks.
  @doc false
  def speakable(nil), do: "好了。"

  def speakable(text) do
    text
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/[*_`#>]+/, "")
    |> String.trim()
    |> case do
      "" -> "好了。"
      spoken -> spoken
    end
  end

  # The standing session, started or brought back as needed.
  defp session do
    case File.read(pointer()) do
      {:ok, id} -> reuse(String.trim(id))
      {:error, _} -> start()
    end
  end

  defp reuse(id) do
    cond do
      not Loom.Agent.Store.valid_id?(id) -> start()
      Agent.flagged?(id) -> start()
      Agent.exists?(id) -> {:ok, id}
      match?({:ok, _}, Loom.Agent.Store.read_meta(id)) -> restore(id)
      true -> start()
    end
  end

  defp restore(id) do
    case Agent.restore_session(id) do
      {:ok, _} -> {:ok, id}
      _ -> start()
    end
  end

  defp start do
    id = Agent.new_id()

    with {:ok, _} <- Agent.start_session(id, backend: :claude_code, title: "Siri", warm: true),
         :ok <- File.write(pointer(), id) do
      {:ok, id}
    end
  end

  defp pointer, do: Path.join(Application.fetch_env!(:loom, :home), "siri-session")

  @doc """
  Whether `given` is the ask key (`LOOM_ASK_KEY`). Without one configured the
  door is shut: nothing matches.
  """
  def valid_key?(given) when is_binary(given) and given != "" do
    case Application.get_env(:loom, :ask_key) do
      key when is_binary(key) and byte_size(key) >= 24 -> Plug.Crypto.secure_compare(given, key)
      _ -> false
    end
  end

  def valid_key?(_), do: false
end
