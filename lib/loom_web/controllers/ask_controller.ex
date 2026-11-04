defmodule LoomWeb.AskController do
  @moduledoc """
  POST /api/ask `{"text": "..."}` → `{"reply": "..."}`, for a voice shortcut.

  Not behind the login token: it takes its own key (`LOOM_ASK_KEY`, as
  `Authorization: Bearer <key>`), which opens this route and nothing else, so
  the phone that holds it never holds a token for the rest of the API. With no
  key configured the route answers 404. See `Loom.Ask`.
  """
  use LoomWeb, :controller

  def create(conn, params) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         true <- Loom.Ask.valid_key?(key) do
      answer(conn, String.trim(to_string(params["text"] || "")))
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp answer(conn, ""), do: json(conn, %{reply: "我没听清，再说一次？"})

  defp answer(conn, text) do
    case Loom.Ask.ask(text) do
      {:ok, reply} -> json(conn, %{reply: reply})
      :pending -> json(conn, %{reply: "还在做，做完的结果在 Loom 的 Siri 会话里。"})
      {:error, _} -> json(conn, %{reply: "出错了，去 Loom 里看看吧。"})
    end
  end
end
