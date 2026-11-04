defmodule LoomWeb.AskControllerTest do
  use LoomWeb.ConnCase, async: false

  @key "test-ask-key-0123456789abcdef"

  setup do
    previous = Application.get_env(:loom, :ask_key)
    Application.put_env(:loom, :ask_key, @key)
    on_exit(fn -> Application.put_env(:loom, :ask_key, previous) end)
  end

  test "without the key it is not there", %{conn: conn} do
    assert conn |> post("/api/ask", %{text: "hi"}) |> json_response(404)
  end

  test "the login token does not open it", %{conn: conn} do
    conn
    |> put_req_header("authorization", "Bearer " <> Loom.Auth.mint_token())
    |> post("/api/ask", %{text: "hi"})
    |> json_response(404)
  end

  test "shut when no key is configured", %{conn: conn} do
    Application.put_env(:loom, :ask_key, nil)

    conn
    |> put_req_header("authorization", "Bearer ")
    |> post("/api/ask", %{text: "hi"})
    |> json_response(404)
  end

  test "an empty question is answered without a turn", %{conn: conn} do
    assert %{"reply" => _} =
             conn
             |> put_req_header("authorization", "Bearer " <> @key)
             |> post("/api/ask", %{text: "  "})
             |> json_response(200)
  end

  test "speakable drops reply blocks and Markdown" do
    assert Loom.Ask.speakable("**开了**灯。\n\n<!-- loom:replies\n好\n-->") == "开了灯。"
    assert Loom.Ask.speakable(nil) == "好了。"
  end
end
