defmodule LoomWeb.TaskControllerTest do
  # Not async: the stub, the backend map and Loom.Cron are global.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-tctl-#{System.unique_integer([:positive])}")
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
      for job <- Loom.Cron.list(), do: Loom.Cron.delete(job.id)
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Application.delete_env(:loom, Loom.Cron.Describe)
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

  test "a task gets a session of its own, in Shanghai time by default", %{conn: conn} do
    task =
      conn
      |> post(~p"/api/tasks", %{name: "Morning news", prompt: "the news", cron: "0 9 * * *"})
      |> json_response(201)

    assert %{"name" => "Morning news", "utc_offset" => 480, "paused" => false, "target" => target} =
             task

    # Hidden from the sidebar's lists, opened from the task.
    assert {:ok, %{title: "Morning news", kind: "task"}} = Loom.Agent.Store.read_meta(target)
    assert {:ok, next, _} = DateTime.from_iso8601(task["next_at"])
    assert next.hour == 1

    assert %{"tasks" => [%{"id" => _}], "utc_offset" => 480} =
             conn |> get(~p"/api/tasks") |> json_response(200)
  end

  test "said in words, read, and made", %{conn: conn} do
    Application.put_env(:loom, Loom.Cron.Describe,
      ask: fn _, _ -> {:ok, ~s({"name": "周报", "prompt": "写周报", "cron": "0 9 * * 1"})} end
    )

    assert %{"name" => "周报", "prompt" => "写周报", "cron" => "0 9 * * 1"} =
             conn |> post(~p"/api/tasks", %{text: "每周一九点写周报"}) |> json_response(201)
  end

  test "a refusal leaves no session behind", %{conn: conn} do
    before = length(Agent.list_sessions())

    assert %{"error" => _} =
             conn |> post(~p"/api/tasks", %{prompt: "x", cron: "nonsense"}) |> json_response(422)

    Process.sleep(50)
    assert length(Agent.list_sessions()) == before
  end

  test "edit, pause, run and delete; the session stays", %{conn: conn} do
    %{"id" => id, "target" => target} =
      conn |> post(~p"/api/tasks", %{prompt: "ping", cron: "0 9 * * *"}) |> json_response(201)

    assert %{"paused" => true, "next_at" => nil} =
             conn |> patch(~p"/api/tasks/#{id}", %{paused: true}) |> json_response(200)

    assert %{"prompt" => "pong"} =
             conn |> patch(~p"/api/tasks/#{id}", %{prompt: "pong"}) |> json_response(200)

    conn |> post(~p"/api/tasks/#{id}/run") |> json_response(200)
    assert BackendStub.await_turn() == "pong"

    assert conn |> delete(~p"/api/tasks/#{id}") |> response(204)
    assert conn |> patch(~p"/api/tasks/#{id}", %{paused: false}) |> json_response(404)
    assert Agent.exists?(target)
  end
end
