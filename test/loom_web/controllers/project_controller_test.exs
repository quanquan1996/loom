defmodule LoomWeb.ProjectControllerTest do
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias Loom.Projects

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-pctl-#{System.unique_integer([:positive])}")
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
      for p <- Projects.list(), do: Projects.delete(p.id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Loom.Auth.mint_token())
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  defp create_project(conn, attrs) do
    conn |> post(~p"/api/projects", attrs) |> json_response(201)
  end

  test "creates, lists, updates and refuses", %{conn: conn} do
    %{"id" => id, "workspace" => ws} = create_project(conn, %{name: "Blog"})
    assert File.dir?(ws)

    assert %{"projects" => [%{"id" => ^id}]} = conn |> get(~p"/api/projects") |> json_response(200)

    assert %{"name" => "Blog 2", "instructions" => "Short."} =
             conn
             |> patch(~p"/api/projects/#{id}", %{name: "Blog 2", instructions: "Short."})
             |> json_response(200)

    assert %{"error" => _} = conn |> post(~p"/api/projects", %{name: ""}) |> json_response(422)
    assert conn |> patch(~p"/api/projects/p_nope", %{name: "x"}) |> json_response(404)
  end

  test "a session made in a project starts in its workspace and is told so", %{conn: conn} do
    %{"id" => pid, "workspace" => ws} =
      create_project(conn, %{name: "Novel", instructions: "Use British spelling."})

    %{"id" => id, "project_id" => ^pid} =
      conn |> post(~p"/api/agents", %{backend: "claude_code", project_id: pid}) |> json_response(201)

    meta = BackendStub.last_meta()
    assert meta.cc_cwd == ws
    assert meta.instructions =~ ~s("Novel")
    assert meta.instructions =~ "Use British spelling."
    assert {:ok, %{project_id: ^pid}} = Loom.Agent.Store.read_meta(id)
  end

  test "editing a project hands its sessions the new instructions", %{conn: conn} do
    %{"id" => pid, "workspace" => ws} = create_project(conn, %{name: "Live"})
    conn |> post(~p"/api/agents", %{backend: "claude_code", project_id: pid}) |> json_response(201)
    conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    conn |> patch(~p"/api/projects/#{pid}", %{instructions: "New rules."}) |> json_response(200)
    assert_receive {:stub_relocated, ^ws, instructions}
    assert instructions =~ "New rules."
    # Only the session in the project.
    refute_receive {:stub_relocated, _, _}, 100
  end

  test "a loose session moves into a project, carrying on in its workspace", %{conn: conn} do
    %{"id" => pid, "workspace" => ws} = create_project(conn, %{name: "Home", instructions: "Be brief."})
    %{"id" => id} = conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    assert %{"project_id" => ^pid} =
             conn |> patch(~p"/api/agents/#{id}", %{project_id: pid}) |> json_response(200)

    assert_receive {:stub_relocated, ^ws, instructions}
    assert instructions =~ ~s("Home")
    assert instructions =~ "Be brief."
    assert {:ok, %{project_id: ^pid}} = Loom.Agent.Store.read_meta(id)

    # And out again, to the default directory and Loom's own instructions.
    assert %{"project_id" => nil} =
             conn |> patch(~p"/api/agents/#{id}", %{project_id: nil}) |> json_response(200)

    assert_receive {:stub_relocated, nil, instructions}
    refute instructions =~ "Home"
  end

  test "a move is refused mid-turn, and to a project that does not exist", %{conn: conn} do
    %{"id" => pid} = create_project(conn, %{name: "Busy"})
    %{"id" => id} = conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    assert %{"error" => "no such project"} =
             conn |> patch(~p"/api/agents/#{id}", %{project_id: "p_nope"}) |> json_response(422)

    {:ok, :started} = Agent.submit(id, "work")
    BackendStub.await_turn()

    assert %{"error" => "the session is in the middle of a turn"} =
             conn |> patch(~p"/api/agents/#{id}", %{project_id: pid}) |> json_response(422)

    assert Agent.info(id).project_id == nil
  end

  test "pinning is kept in the header", %{conn: conn} do
    %{"id" => id, "pinned" => false} =
      conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    assert %{"pinned" => true} = conn |> patch(~p"/api/agents/#{id}", %{pinned: true}) |> json_response(200)
    assert {:ok, %{pinned: true}} = Loom.Agent.Store.read_meta(id)
    assert %{"pinned" => false} = conn |> patch(~p"/api/agents/#{id}", %{pinned: false}) |> json_response(200)
  end

  test "a session outside any project has no project and no cwd", %{conn: conn} do
    %{"project_id" => nil} =
      conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    assert BackendStub.last_meta().cc_cwd == nil
  end

  test "an unknown project is refused", %{conn: conn} do
    assert %{"error" => "no such project"} =
             conn
             |> post(~p"/api/agents", %{backend: "claude_code", project_id: "p_nope"})
             |> json_response(422)

    assert Agent.list_sessions() == []
  end

  test "the tree lists the workspace, and its files download", %{conn: conn} do
    %{"id" => pid, "workspace" => ws} = create_project(conn, %{name: "Data"})
    File.write!(Path.join(ws, "data.csv"), "a,b\n")

    %{"id" => id} =
      conn |> post(~p"/api/agents", %{backend: "claude_code", project_id: pid}) |> json_response(201)

    assert %{"workspace" => [%{"path" => "data.csv"}], "workspace_truncated" => false} =
             conn |> get(~p"/api/agents/#{id}/tree") |> json_response(200)

    assert conn |> get(~p"/api/agents/#{id}/workspace/data.csv") |> response(200) == "a,b\n"
    assert conn |> get(~p"/api/agents/#{id}/workspace/nope.csv") |> json_response(404)
  end

  test "a session outside a project has no workspace in its tree", %{conn: conn} do
    %{"id" => id} = conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)
    refute Map.has_key?(conn |> get(~p"/api/agents/#{id}/tree") |> json_response(200), "workspace")
  end

  test "deleting a project deletes its sessions, not others", %{conn: conn} do
    %{"id" => pid, "workspace" => ws} = create_project(conn, %{name: "Gone"})

    %{"id" => inside} =
      conn |> post(~p"/api/agents", %{backend: "claude_code", project_id: pid}) |> json_response(201)

    %{"id" => outside} =
      conn |> post(~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

    assert conn |> delete(~p"/api/projects/#{pid}") |> response(204)
    refute Agent.exists?(inside)
    assert Loom.Agent.Store.read_meta(inside) == :error
    assert Agent.exists?(outside)
    refute File.exists?(ws)
  end
end
