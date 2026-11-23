defmodule LoomWeb.ForwardSocket do
  @moduledoc """
  A WebSocket carrying one TCP connection to a port on one of the user's
  devices — in practice VNC (RFB), drawn by noVNC on the page, like
  `LoomWeb.VncSocket` does for loom's own browser. Bytes go through untouched;
  the far end is `loom-node` on the device (`node/forward.go`), reached over
  its `LoomWeb.NodeChannel`, which dials the port on its own loopback.

  It opens only while the device's forwarding is switched on (`Loom.Nodes`),
  and closes the moment it is switched off, times out, or the device drops.
  The user's keys and pointer keep the switch's idle clock going; the screen
  merely changing does not, so a forgotten pane still lets it lapse.
  """
  @behaviour WebSock

  require Logger

  # A device whose loom-node predates forwarding ignores the request.
  @open_timeout :timer.seconds(10)
  # How often the user's input restarts the idle clock, at most.
  @touch_every :timer.seconds(60)

  @impl true
  def init(%{node_id: node_id, node_name: name, port: port, channel: channel, ip: ip}) do
    id = "fw_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Loom.PubSub, "forwards")
    Process.monitor(channel)
    send(channel, {:node_send, self(), id, "forward_open", %{"port" => port}})
    timer = Process.send_after(self(), :open_timeout, @open_timeout)
    Logger.info("Forward #{id}: #{ip} → #{name}:#{port}")

    {:ok,
     %{
       id: id,
       node_id: node_id,
       name: name,
       port: port,
       channel: channel,
       open: false,
       timer: timer,
       pending: [],
       touched: 0
     }}
  end

  # Input before the device has opened the port waits, in order.
  @impl true
  def handle_in({data, opcode: :binary}, %{open: false} = s),
    do: {:ok, %{s | pending: [data | s.pending]}}

  def handle_in({data, opcode: :binary}, s) do
    send_in(s, data)
    {:ok, touch(s, data)}
  end

  def handle_in(_text, s), do: {:ok, s}

  @impl true
  def handle_info({:node_reply, id, "forward_opened", _}, %{id: id} = s) do
    Process.cancel_timer(s.timer)
    s.pending |> Enum.reverse() |> Enum.each(&send_in(s, &1))
    {:ok, %{s | open: true, pending: []}}
  end

  def handle_info({:node_reply, id, "forward_out", %{"data" => data}}, %{id: id} = s) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:push, {:binary, bytes}, s}
      :error -> {:ok, s}
    end
  end

  def handle_info({:node_reply, id, "forward_closed", _}, %{id: id} = s),
    do: close(s, 1000, "the port closed")

  def handle_info({:node_reply, id, "error", %{"message" => message}}, %{id: id} = s),
    do: close(s, 1011, message)

  def handle_info(:open_timeout, %{open: false} = s),
    do:
      close(s, 1011, "#{s.name} did not open the port; its loom-node may predate port forwarding")

  def handle_info({:forward_off, node_id}, %{node_id: node_id} = s),
    do: close(s, 1000, "port forwarding was switched off")

  def handle_info({:DOWN, _ref, :process, channel, _}, %{channel: channel} = s),
    do: close(s, 1011, "#{s.name} disconnected")

  def handle_info(_, s), do: {:ok, s}

  @impl true
  def terminate(_reason, s) do
    send(s.channel, {:node_cancel, s.id})
    Logger.info("Forward #{s.id}: closed")
    :ok
  end

  defp send_in(s, data),
    do:
      send(s.channel, {:node_send, self(), s.id, "forward_in", %{"data" => Base.encode64(data)}})

  # noVNC sends each client message in a frame of its own, so a frame that
  # starts with KeyEvent (4) or PointerEvent (5) is the user at work; update
  # requests (3), which come whenever the screen changes, are not.
  defp touch(s, <<type, _::binary>>) when type in [4, 5] do
    now = System.monotonic_time(:millisecond)

    if now - s.touched >= @touch_every do
      Loom.Nodes.forward_touch(s.node_id)
      %{s | touched: now}
    else
      s
    end
  end

  defp touch(s, _data), do: s

  # Close frame reasons are capped at 123 bytes.
  defp close(s, code, reason),
    do: {:stop, :normal, {code, binary_part(reason, 0, min(byte_size(reason), 123))}, s}
end
