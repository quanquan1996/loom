defmodule LoomWeb.SearchController do
  @moduledoc "The sidebar's search over each session's title and what was said; see `Loom.Agent.Search.ranked/2`."
  use LoomWeb, :controller

  # GET /api/search?q=words
  def index(conn, params) do
    query = if is_binary(params["q"]), do: params["q"], else: ""
    # Incognito sessions are found only in Settings.
    infos = for s <- Loom.Agent.list_sessions(), s.kind != "incognito", do: s
    json(conn, %{results: Loom.Agent.Search.ranked(infos, query)})
  end
end
