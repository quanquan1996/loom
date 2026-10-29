defmodule LoomWeb.SearchController do
  @moduledoc "The sidebar's search over what was said in each session; see `Loom.Agent.Search`."
  use LoomWeb, :controller

  # GET /api/search?q=words
  def index(conn, params) do
    query = if is_binary(params["q"]), do: params["q"], else: ""
    ids = Enum.map(Loom.Agent.list_sessions(), & &1.id)
    json(conn, %{results: Loom.Agent.Search.run(ids, query)})
  end
end
