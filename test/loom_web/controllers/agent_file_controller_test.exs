defmodule LoomWeb.AgentFileControllerTest do
  @moduledoc """
  The upload endpoint.

  Attachments go over HTTP rather than the channel, so this is where the session
  id has to be checked: an unknown one must not create a directory, and it must
  certainly not be usable as a path.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-up-#{System.unique_integer([:positive])}")
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

    id = "a_up#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    conn = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())

    {:ok, conn: conn, id: id}
  end

  defp upload(filename, content, type \\ "text/plain") do
    path = Path.join(System.tmp_dir!(), "up-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{filename: filename, path: path, content_type: type}
  end

  test "stores a file and reports its path", %{conn: conn, id: id} do
    conn = post(conn, ~p"/api/agents/#{id}/files", %{"files" => [upload("a.txt", "hello")]})

    assert %{"files" => [file]} = json_response(conn, 200)
    assert file["name"] == "a.txt"
    assert file["size"] == 5
    assert file["path"] == Path.join(Store.files_dir(id), "a.txt")
    assert File.read!(file["path"]) == "hello"
  end

  test "takes several files in one request", %{conn: conn, id: id} do
    conn =
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [upload("a.txt", "one"), upload("b.txt", "two")]
      })

    assert %{"files" => [_, _]} = json_response(conn, 200)
  end

  test "an unknown session is a 404 and writes nothing", %{conn: conn} do
    conn = post(conn, ~p"/api/agents/a_nope/files", %{"files" => [upload("a.txt", "hi")]})

    assert json_response(conn, 404)
    refute File.exists?(Store.files_dir("a_nope"))
  end

  test "a request with no file says so", %{conn: conn, id: id} do
    conn = post(conn, ~p"/api/agents/#{id}/files", %{})
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "no files"
  end

  test "an oversized file is refused and the good ones are not left behind", %{
    conn: conn,
    id: id
  } do
    # All or nothing: a half-stored drop would leave the user guessing which of
    # the files the agent is about to see.
    conn =
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [
          upload("fine.txt", "ok"),
          upload("big.bin", String.duplicate("x", 26 * 1024 * 1024))
        ]
      })

    assert json_response(conn, 413)
    assert File.ls!(Store.files_dir(id)) == []
  end

  test "requires a token", %{id: id} do
    conn =
      build_conn()
      |> post(~p"/api/agents/#{id}/files", %{"files" => [upload("a.txt", "hi")]})

    assert json_response(conn, 401)
  end

  describe "reading an attachment back" do
    test "serves a file this session stored", %{conn: conn, id: id} do
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [upload("shot.png", "PNG", "image/png")]
      })

      conn = get(conn, "/api/agents/#{id}/files/shot.png")
      assert response(conn, 200) == "PNG"
      # Behind the token, so never in a shared cache; a stored name is never
      # rewritten, so the browser may keep it.
      assert get_resp_header(conn, "cache-control") == ["private, max-age=86400"]
    end

    test "anything outside the session's files is a 404", %{conn: conn, id: id} do
      File.mkdir_p!(Store.files_dir(id))
      File.write!(Path.join(Store.session_dir(id), "meta-ish.json"), "{}")

      for name <- ["missing.png", "..", "%2e%2e", "..%2fmeta-ish.json"] do
        assert json_response(get(conn, "/api/agents/#{id}/files/#{name}"), 404),
               "#{name} should not be served"
      end
    end

    test "an unknown session is a 404", %{conn: conn} do
      assert json_response(get(conn, "/api/agents/a_nobody/files/x.png"), 404)
    end

    test "requires a token", %{id: id} do
      assert json_response(get(build_conn(), "/api/agents/#{id}/files/x.png"), 401)
    end
  end

  describe "renaming and deleting an attachment" do
    setup %{conn: conn, id: id} do
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [upload("a.txt", "hi"), upload("b.txt", "yo")]
      })

      :ok
    end

    test "renames, refusing a taken name", %{conn: conn, id: id} do
      assert %{"path" => "截图.txt"} =
               conn
               |> patch("/api/agents/#{id}/files/a.txt", %{new_name: "截图.txt"})
               |> json_response(200)

      assert File.read!(Path.join(Store.files_dir(id), "截图.txt")) == "hi"

      assert conn
             |> patch("/api/agents/#{id}/files/#{URI.encode("截图.txt")}", %{new_name: "b.txt"})
             |> json_response(409)

      assert conn
             |> patch("/api/agents/#{id}/files/b.txt", %{new_name: "../b.txt"})
             |> json_response(422)
    end

    test "deletes, and only its own", %{conn: conn, id: id} do
      File.write!(Path.join(Store.session_dir(id), "meta-ish.json"), "{}")
      assert conn |> delete("/api/agents/#{id}/files/..%2fmeta-ish.json") |> json_response(404)
      assert File.exists?(Path.join(Store.session_dir(id), "meta-ish.json"))

      assert conn |> delete("/api/agents/#{id}/files/a.txt") |> response(204)
      refute File.exists?(Path.join(Store.files_dir(id), "a.txt"))
    end
  end

  describe "a file sent in parts" do
    defp part(conn, id, upload, offset, size, body, name \\ "big.bin") do
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer " <> Loom.Auth.mint_token())
      |> put_req_header("content-type", "application/octet-stream")
      |> put(~p"/api/agents/#{id}/files/parts/#{upload}?#{[offset: offset, size: size, name: name]}", body)
    end

    test "parts are appended in order and the last one names the file", %{conn: conn, id: id} do
      assert %{"received" => 4} = conn |> part(id, "upload-0001", 0, 10, "abcd") |> json_response(200)
      assert Loom.Agent.Files.list(id) == []
      assert %{"received" => 8} = conn |> part(id, "upload-0001", 4, 10, "efgh") |> json_response(200)
      assert %{"file" => file} = conn |> part(id, "upload-0001", 8, 10, "ij") |> json_response(200)

      assert file["name"] == "big.bin"
      assert file["size"] == 10
      assert File.read!(file["path"]) == "abcdefghij"
      assert [%{path: "big.bin"}] = Loom.Agent.Files.list(id)
      assert {:ok, [_]} = Loom.Agent.Files.verify(id, [file["path"]])
    end

    test "a part that does not start where the file ends is refused, and says where that is", %{conn: conn, id: id} do
      conn |> part(id, "upload-0002", 0, 10, "abcd") |> json_response(200)
      assert %{"received" => 4} = conn |> part(id, "upload-0002", 0 + 6, 10, "ghij") |> json_response(409)
      # The reply to a part was lost and it is sent again: the same answer.
      assert %{"received" => 4} = conn |> part(id, "upload-0002", 2, 10, "cd") |> json_response(409)
      assert %{"file" => _} = conn |> part(id, "upload-0002", 4, 10, "efghij") |> json_response(200)
    end

    test "a part at 0 starts over; a part past the end is dropped", %{conn: conn, id: id} do
      conn |> part(id, "upload-0003", 0, 6, "xxxx") |> json_response(200)
      conn |> part(id, "upload-0003", 0, 6, "abc") |> json_response(200)
      assert conn |> part(id, "upload-0003", 3, 6, "defgh") |> json_response(413)
      assert %{"file" => file} = conn |> part(id, "upload-0003", 3, 6, "def") |> json_response(200)
      assert File.read!(file["path"]) == "abcdef"
    end

    test "the name is made safe and never reuses one that is taken", %{conn: conn, id: id} do
      assert %{"file" => a} = conn |> part(id, "upload-0004", 0, 1, "a", "../../etc/x.txt") |> json_response(200)
      assert %{"file" => b} = conn |> part(id, "upload-0005", 0, 1, "b", "x.txt") |> json_response(200)
      assert a["path"] == Path.join(Store.files_dir(id), "x.txt")
      assert b["name"] == "x-1.txt"
    end

    test "what is refused outright", %{conn: conn, id: id} do
      assert conn |> part(id, "upload-0006", 0, 600 * 1024 * 1024, "a") |> json_response(413)
      assert conn |> part(id, "../../x", 0, 4, "a") |> json_response(422)
      assert conn |> part(id, "bad id!!", 0, 4, "a") |> json_response(422)
      assert conn |> part(id, "upload-0007", 4, 10, "a") |> json_response(404)
      assert conn |> part(id, "upload-0008", 0, 0, "") |> json_response(422)
      assert conn |> part("a_nosuchsession", "upload-0009", 0, 4, "a") |> json_response(404)
      refute File.exists?(Path.join(Store.files_dir("a_nosuchsession"), ".part-upload-0009"))
    end
  end
end
