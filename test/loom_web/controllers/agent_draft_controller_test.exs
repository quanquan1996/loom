defmodule LoomWeb.AgentDraftControllerTest do
  @moduledoc "A session's unsent composer text, kept for the next device to open it."
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-draft-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    id = "a_dr#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    conn = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())
    %{conn: conn, id: id}
  end

  test "none at first, then what was put, then none once cleared", %{conn: conn, id: id} do
    assert %{"text" => "", "updated_at" => nil} = conn |> get("/api/agents/#{id}/draft") |> json_response(200)

    assert %{"text" => "half a thought", "updated_at" => at} =
             conn |> put("/api/agents/#{id}/draft", %{text: "half a thought"}) |> json_response(200)

    assert is_integer(at)
    assert %{"text" => "half a thought"} = conn |> get("/api/agents/#{id}/draft") |> json_response(200)
    assert File.exists?(Path.join(Store.session_dir(id), "draft.json"))

    conn |> put("/api/agents/#{id}/draft", %{text: ""}) |> json_response(200)
    assert %{"text" => ""} = conn |> get("/api/agents/#{id}/draft") |> json_response(200)
    refute File.exists?(Path.join(Store.session_dir(id), "draft.json"))
  end

  test "an unknown session is not a path", %{conn: conn} do
    assert conn |> get("/api/agents/..%2F..%2Fetc/draft") |> json_response(404)
    assert conn |> put("/api/agents/a_nope/draft", %{text: "x"}) |> json_response(404)
  end

  test "text must be a string, and not an enormous one", %{conn: conn, id: id} do
    assert conn |> put("/api/agents/#{id}/draft", %{text: 3}) |> json_response(422)
    big = String.duplicate("x", Loom.Agent.Draft.limit() + 1)
    assert conn |> put("/api/agents/#{id}/draft", %{text: big}) |> json_response(413)
  end
end
