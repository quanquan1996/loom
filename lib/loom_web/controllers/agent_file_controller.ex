defmodule LoomWeb.AgentFileController do
  @moduledoc """
  Uploads for one session's attachments.

  Separate from the channel on purpose: a WebSocket frame is a poor transport
  for a 20 MB screenshot (it would sit in front of every event and delta on the
  same socket), and multipart gives us the upload already spooled to a temp file
  instead of base64 in memory.

  The response carries the absolute paths. The client hands them back with the
  next `submit`, where `Loom.Agent.Files.verify/2` checks they are this
  session's own before the model is told about them.
  """
  use LoomWeb, :controller

  require Logger

  alias Loom.Agent
  alias Loom.Agent.Files
  alias Loom.Agent.Store

  # POST /api/agents/:id/files — multipart, one or many `files[]`.
  def create(conn, %{"id" => id} = params) do
    cond do
      # Also what keeps the id from being a path: an unknown one has no process.
      not Agent.exists?(id) ->
        conn |> put_status(:not_found) |> json(%{error: "unknown session"})

      uploads(params) == [] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "no files in the request"})

      true ->
        store_all(conn, id, uploads(params))
    end
  end

  # PUT /api/agents/:id/files/parts/:upload?offset=&size=&name= — the next part
  # of a large file, as the raw body. `200 %{received:}` until the last part,
  # which answers `%{file:}` as `create` would; `409 %{received:}` when the
  # part does not start where the file ends. See `Files.open_part/4`.
  def part(conn, %{"id" => id, "upload" => upload} = params) do
    with true <- Agent.exists?(id),
         {offset, ""} <- Integer.parse(params["offset"] || ""),
         {total, ""} <- Integer.parse(params["size"] || ""),
         {:ok, io, path} <- Files.open_part(id, upload, offset, total) do
      {result, conn} = read_part(conn, io, 0)
      File.close(io)

      case result do
        {:ok, written} -> part_done(conn, Files.close_part(path, offset, written, total, params["name"] || "file"))
        {:error, reason} -> part_done(conn, Files.undo_part(path, offset, reason))
      end
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "unknown session"})
      {:error, reason} -> part_done(conn, {:error, reason})
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: "offset and size are needed"})
    end
  end

  defp read_part(conn, io, written) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {state, data, conn} when state in [:ok, :more] ->
        written = written + byte_size(data)

        cond do
          written > Files.part_request() -> {{:error, :part_too_large}, conn}
          :file.write(io, data) != :ok -> {{:error, :interrupted}, conn}
          state == :more -> read_part(conn, io, written)
          true -> {{:ok, written}, conn}
        end

      {:error, _reason} ->
        {{:error, :interrupted}, conn}
    end
  end

  defp part_done(conn, {:ok, file}), do: json(conn, %{file: file})
  defp part_done(conn, {:more, size}), do: json(conn, %{received: size})

  defp part_done(conn, {:error, {:offset, size}}),
    do: conn |> put_status(:conflict) |> json(%{error: "the part does not start where the file ends", received: size})

  defp part_done(conn, {:error, reason}),
    do: conn |> put_status(status_for(reason)) |> json(%{error: message_for(reason)})

  # GET /api/agents/:id/files/:name — an attachment read back, for the
  # thumbnail in the bubble that sent it. The same check as a submit: only a
  # regular file inside this session's own `files/` is served.
  #
  # Cached a day, privately: behind the token, and an attachment is not
  # rewritten — `Files.store/2` never reuses a name that is taken. A name freed
  # by a delete or a rename could come back as a different file, and a browser
  # that saw the old one would show that for up to the day.
  def show(conn, %{"id" => id, "name" => name}) do
    with true <- Agent.exists?(id),
         {:ok, [file]} <- Files.verify(id, [Path.join(Store.files_dir(id), name)]) do
      conn
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_download({:file, file.path}, filename: file.name)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  # DELETE /api/agents/:id/files/:name
  def delete(conn, %{"id" => id, "name" => name}) do
    with true <- Agent.exists?(id), :ok <- Files.delete(id, name) do
      send_resp(conn, :no_content, "")
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  # PATCH /api/agents/:id/files/:name {new_name} — not `name`, which the route has.
  def update(conn, %{"id" => id, "name" => name, "new_name" => new_name}) do
    with true <- Agent.exists?(id), {:ok, stored} <- Files.rename(id, name, new_name) do
      json(conn, %{path: stored})
    else
      {:error, reason} -> LoomWeb.AgentOutputController.rename_failed(conn, reason)
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  defp store_all(conn, id, uploads) do
    results = Enum.map(uploads, &Files.store(id, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        json(conn, %{files: Enum.map(results, fn {:ok, file} -> file end)})

      {:error, reason} ->
        # All or nothing: a half-attached drop would leave the user guessing
        # which of the five files the agent is about to see.
        for {:ok, file} <- results, do: File.rm(file.path)
        conn |> put_status(status_for(reason)) |> json(%{error: message_for(reason)})
    end
  end

  defp status_for(:too_large), do: :request_entity_too_large
  defp status_for(:part_too_large), do: :request_entity_too_large
  defp status_for(:no_space), do: :insufficient_storage
  defp status_for(:unknown_upload), do: :not_found
  defp status_for(_other), do: :unprocessable_entity

  defp message_for(:too_large), do: "a file is larger than the limit (25 MB at once, 500 MB in parts)"
  defp message_for(:part_too_large), do: "a part is larger than 16 MB"
  defp message_for(:no_space), do: "not enough disk space on the server for this file"
  defp message_for(:unknown_upload), do: "this upload is not known; start it again"
  defp message_for(:bad_upload), do: "not a valid part"
  defp message_for(:interrupted), do: "the upload was interrupted"
  defp message_for(:empty), do: "a file is empty"
  defp message_for(reason), do: "could not store the file: #{inspect(reason)}"

  # `files[]` is the normal case; `file` is accepted so a one-off `curl -F` works.
  defp uploads(params) do
    [Map.get(params, "files"), Map.get(params, "file")]
    |> Enum.flat_map(fn
      %Plug.Upload{} = upload -> [upload]
      list when is_list(list) -> Enum.filter(list, &match?(%Plug.Upload{}, &1))
      _ -> []
    end)
  end
end
