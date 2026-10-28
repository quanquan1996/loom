defmodule Loom.Browser do
  @moduledoc """
  The shape of loom's browser's window (`rel/browser/loom-browser.sh`).

  It is a desktop window, 1280×800, which on a phone is either too small to read
  or a keyhole to pan around. So a phone viewing it (`LoomWeb.VncSocket` with a
  size) narrows the window to the shape of its pane; the sites then lay
  themselves out for a narrow screen, and that viewer is shown just this part of
  the display. When the last such viewer leaves, the window is put back.

  The window is shared — agents drive the same Chromium — so while a phone
  looks, their pages are narrow too. The latest phone to arrive sets the shape.
  """
  use GenServer

  require Logger

  alias Loom.Browser.CDP

  # Chromium won't make a window narrower than this.
  @min_width 500
  @min_height 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Narrows the window for the calling process, until it exits, to about `w`×`h`
  — scaled up to the narrowest a window may be, and down to fit the display.
  Returns the window's bounds as they came out, `{width, height}` from the top
  left of the display.
  """
  def narrow(w, h) do
    GenServer.call(__MODULE__, {:narrow, self(), w, h}, 10_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "The display's size, which the window fills unless a phone is looking."
  def screen do
    with [w, h] <- String.split(System.get_env("LOOM_BROWSER_SIZE", "1280x800"), "x"),
         {w, ""} <- Integer.parse(w),
         {h, ""} <- Integer.parse(h) do
      {w, h}
    else
      _ -> {1280, 800}
    end
  end

  @impl true
  def init(_) do
    # Not knowing whether loom went down with a phone looking, put the window
    # back; a browser that isn't running is no matter.
    {:ok, %{viewers: []}, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    _ = resize(screen())
    {:noreply, state}
  end

  @impl true
  def handle_call({:narrow, pid, w, h}, _from, state) do
    ref = Process.monitor(pid)
    viewers = [{pid, ref, fit(w, h)} | state.viewers]
    {:reply, resize(fit(w, h)), %{state | viewers: viewers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    viewers = Enum.reject(state.viewers, fn {_, r, _} -> r == ref end)

    case viewers do
      [] -> resize(screen())
      [{_, _, size} | _] -> resize(size)
    end
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("loom browser: couldn't resize its window: #{inspect(reason)}")
    end

    {:noreply, %{state | viewers: viewers}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Keeps the aspect of the pane asked for: wider to the minimum, then smaller
  # to fit the display.
  defp fit(w, h) do
    {sw, sh} = screen()
    {w, h} = if w < @min_width, do: {@min_width, h * @min_width / max(w, 1)}, else: {w, h}
    scale = min(1.0, min(sw / w, sh / h))
    {max(round(w * scale), @min_width), max(round(h * scale), @min_height)}
  end

  # Every window gets the size, as each sits at the display's top left; a
  # maximized one has to be made normal before it may be sized.
  defp resize({w, h}) do
    CDP.session(fn call ->
      with {:ok, %{"targetInfos" => targets}} <- call.("Target.getTargets", %{}) do
        windows =
          for %{"type" => "page", "targetId" => id} <- targets,
              {:ok, %{"windowId" => window}} <- [
                call.("Browser.getWindowForTarget", %{targetId: id})
              ],
              uniq: true,
              do: window

        for window <- windows do
          call.("Browser.setWindowBounds", %{windowId: window, bounds: %{windowState: "normal"}})
          bounds = %{left: 0, top: 0, width: w, height: h}
          call.("Browser.setWindowBounds", %{windowId: window, bounds: bounds})
        end

        case windows do
          [] ->
            {:ok, {w, h}}

          [window | _] ->
            with {:ok, %{"bounds" => b}} <- call.("Browser.getWindowBounds", %{windowId: window}) do
              {:ok, {b["width"], b["height"]}}
            end
        end
      end
    end)
  end
end

defmodule Loom.Browser.CDP do
  @moduledoc """
  Just enough of the Chrome DevTools Protocol to shape loom's browser's windows:
  one WebSocket to the browser on `127.0.0.1:9222`, a request at a time. Nothing
  is subscribed to, so every frame that comes back is a reply.
  """

  @host {127, 0, 0, 1}
  @port 9222
  @timeout 3_000

  @doc """
  Runs `fun` with a `call.(method, params)` that returns `{:ok, result}` or
  `{:error, reason}`, over one connection, closed after.
  """
  def session(fun) do
    with {:ok, path} <- browser_path(),
         {:ok, sock} <- :gen_tcp.connect(@host, @port, [:binary, active: false], @timeout) do
      try do
        with :ok <- handshake(sock, path) do
          fun.(fn method, params -> call(sock, method, params) end)
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp browser_path do
    with {:ok, sock} <- :gen_tcp.connect(@host, @port, [:binary, active: false], @timeout) do
      :gen_tcp.send(sock, "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      response = read_response(sock, "")
      :gen_tcp.close(sock)

      with {:ok, body} <- response,
           {:ok, %{"webSocketDebuggerUrl" => url}} <- Jason.decode(body) do
        {:ok, URI.parse(url).path}
      else
        _ -> {:error, :no_browser}
      end
    end
  end

  # Up to the end of the body, as `Content-Length` has it: Chromium keeps the
  # connection open, so reading until it closes would wait out the timeout.
  defp read_response(sock, acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, len] <- Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head),
         len = String.to_integer(len),
         true <- byte_size(body) >= len do
      {:ok, binary_part(body, 0, len)}
    else
      _ ->
        with {:ok, data} <- :gen_tcp.recv(sock, 0, @timeout) do
          read_response(sock, acc <> data)
        end
    end
  end

  defp handshake(sock, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :gen_tcp.send(sock, [
      "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nUpgrade: websocket\r\n",
      "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ])

    # The reply is the headers alone: nothing is sent before we ask.
    with {:ok, "HTTP/1.1 101" <> _ = headers} <- read_headers(sock, "") do
      if String.ends_with?(headers, "\r\n\r\n"), do: :ok, else: {:error, :handshake}
    else
      {:ok, _} -> {:error, :handshake}
      error -> error
    end
  end

  defp read_headers(sock, acc) do
    with {:ok, byte} <- :gen_tcp.recv(sock, 1, @timeout) do
      acc = acc <> byte
      if String.ends_with?(acc, "\r\n\r\n"), do: {:ok, acc}, else: read_headers(sock, acc)
    end
  end

  defp call(sock, method, params) do
    id = System.unique_integer([:positive])
    payload = Jason.encode!(%{id: id, method: method, params: params})

    with :ok <- :gen_tcp.send(sock, frame(payload)) do
      reply(sock, id)
    end
  end

  defp reply(sock, id) do
    with {:ok, data} <- read_frame(sock) do
      case Jason.decode(data) do
        {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
        {:ok, %{"id" => ^id, "error" => error}} -> {:error, error}
        _ -> reply(sock, id)
      end
    end
  end

  # A client's frames are masked; a server's are not.
  defp frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)
    key = :binary.copy(mask, div(len, 4) + 1) |> binary_part(0, len)

    length =
      cond do
        len < 126 -> <<1::1, len::7>>
        len < 65_536 -> <<1::1, 126::7, len::16>>
        true -> <<1::1, 127::7, len::64>>
      end

    [<<0x81>>, length, mask, :crypto.exor(payload, key)]
  end

  defp read_frame(sock) do
    with {:ok, <<_::8, 0::1, len::7>>} <- :gen_tcp.recv(sock, 2, @timeout),
         {:ok, len} <- extended(sock, len) do
      if len == 0, do: {:ok, ""}, else: :gen_tcp.recv(sock, len, @timeout)
    else
      {:ok, _} -> {:error, :masked_frame}
      error -> error
    end
  end

  defp extended(sock, 126) do
    with {:ok, <<len::16>>} <- :gen_tcp.recv(sock, 2, @timeout), do: {:ok, len}
  end

  defp extended(sock, 127) do
    with {:ok, <<len::64>>} <- :gen_tcp.recv(sock, 8, @timeout), do: {:ok, len}
  end

  defp extended(_, len), do: {:ok, len}
end
