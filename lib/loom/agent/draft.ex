defmodule Loom.Agent.Draft do
  @moduledoc """
  What the user has typed into a session's composer and not yet sent, kept on
  the server so another device opens the session with it, and a phone that
  dropped the page does not lose it.

  One file per session, `<session_dir>/draft.json`, outside the header: the
  draft changes with every pause in typing, and the header is rewritten and
  announced to every sidebar on each change. Deleting the session deletes its
  directory, and the draft with it.

  The server's copy is the truth. A device keeps its own copy too, marked
  whether it got here; on opening a session it pushes a copy that did not, and
  otherwise takes this one. No clocks are compared, so a phone whose clock is
  off cannot win or lose by it — the last write to arrive wins.
  """

  alias Loom.Agent.Store

  @draft_file "draft.json"

  # Longer than anyone types; a paste of a whole file still fits.
  @limit 200_000

  def limit, do: @limit

  @doc "The draft: `%{text: text, updated_at: ms}`, an empty text if none."
  def read(id) do
    with {:ok, body} <- File.read(path(id)),
         {:ok, %{"text" => text, "updated_at" => at}} when is_binary(text) <- Jason.decode(body) do
      %{text: text, updated_at: at}
    else
      _ -> %{text: "", updated_at: nil}
    end
  end

  @doc "Replace the draft. An empty one removes the file."
  def write(id, text) when is_binary(text) do
    if String.trim(text) == "" do
      File.rm(path(id))
      %{text: "", updated_at: nil}
    else
      draft = %{text: text, updated_at: System.system_time(:millisecond)}
      File.mkdir_p!(Store.session_dir(id))
      tmp = path(id) <> ".tmp"
      File.write!(tmp, Jason.encode_to_iodata!(draft))
      File.rename!(tmp, path(id))
      draft
    end
  end

  defp path(id), do: Path.join(Store.session_dir(id), @draft_file)
end
