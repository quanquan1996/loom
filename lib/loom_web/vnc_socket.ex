defmodule LoomWeb.VncSocket do
  @moduledoc """
  The user's view of loom's own browser: a WebSocket carrying VNC (RFB) to and
  from x11vnc on `127.0.0.1:5900`, which shows the Chromium that
  `rel/browser/loom-browser.sh` keeps running. Bytes go through untouched, the
  way websockify would pass them; noVNC on the page speaks the protocol.

  A phone asks with the size of its pane. Then `Loom.Browser` narrows the
  window to that shape, and this socket starts an x11vnc of its own that shows
  only that corner of the display, so the page fills the phone's pane instead
  of sitting in a desktop-sized screen. That x11vnc serves the one connection
  and exits after it.

  x11vnc has no password and listens on loopback only, so this socket is the
  one way in, and `LoomWeb.BrowserController` lets it open only with a valid
  login token.
  """
  @behaviour WebSock

  @port 5900

  @impl true
  def init(nil), do: connect(@port, 1, nil)

  # A window that couldn't be narrowed is still worth showing as it is.
  def init({w, h}) do
    with {:ok, {w, h}} <- Loom.Browser.narrow(w, h),
         {:ok, port, x11vnc} <- clipped(w, h) do
      connect(port, 30, x11vnc)
    else
      _ -> init(nil)
    end
  end

  # x11vnc takes a moment to listen, so a fresh one is tried a few times.
  defp connect(port, tries, x11vnc) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: :once, nodelay: true], 3_000) do
      {:ok, vnc} ->
        {:ok, %{vnc: vnc, x11vnc: x11vnc}}

      {:error, _} when tries > 1 ->
        Process.sleep(100)
        connect(port, tries - 1, x11vnc)

      {:error, reason} ->
        stop(x11vnc)
        {:stop, {:shutdown, reason}, {1011, "the browser is not running"}, nil}
    end
  end

  # An x11vnc showing the display's top-left `w`×`h`, on a free loopback port:
  # for one viewer (`-once`), and gone if that viewer never comes (`-timeout`).
  defp clipped(w, h) do
    with exe when is_binary(exe) <- System.find_executable("x11vnc"),
         {:ok, listen} <- :gen_tcp.listen(0, ip: {127, 0, 0, 1}),
         {:ok, port} <- :inet.port(listen) do
      :gen_tcp.close(listen)
      display = ":" <> System.get_env("LOOM_BROWSER_DISPLAY", "99")

      args =
        ~w(-display #{display} -localhost -rfbport #{port} -clip #{w}x#{h}+0+0) ++
          ~w(-once -timeout 15 -nopw -quiet -noxdamage)

      {:ok, port, Port.open({:spawn_executable, exe}, [:binary, :stderr_to_stdout, args: args])}
    else
      _ -> {:error, :no_x11vnc}
    end
  end

  defp stop(nil), do: :ok

  defp stop(x11vnc) do
    case Port.info(x11vnc, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    :ok
  end

  @impl true
  def handle_in({data, opcode: :binary}, s) do
    :ok = :gen_tcp.send(s.vnc, data)
    {:ok, s}
  end

  def handle_in(_text, s), do: {:ok, s}

  # One read at a time: the next is asked for only once this one has gone out,
  # so a slow client holds x11vnc back rather than filling this mailbox.
  @impl true
  def handle_info({:tcp, vnc, data}, %{vnc: vnc} = s) do
    :inet.setopts(vnc, active: :once)
    {:push, {:binary, data}, s}
  end

  def handle_info({:tcp_closed, vnc}, %{vnc: vnc} = s), do: {:stop, :normal, s}
  def handle_info({:tcp_error, vnc, _}, %{vnc: vnc} = s), do: {:stop, :normal, s}
  # The clipped x11vnc's own output, and its exit.
  def handle_info(_, s), do: {:ok, s}

  @impl true
  def terminate(_reason, nil), do: :ok

  def terminate(_reason, s) do
    :gen_tcp.close(s.vnc)
    stop(s.x11vnc)
  end
end
