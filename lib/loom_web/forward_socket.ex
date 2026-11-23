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

  ## Peer to peer (`?rtc=1`)

  Opened with `rtc=1`, the socket first carries a WebRTC handshake instead,
  as JSON text frames, so the bytes can go straight between the browser and
  the device (`node/rtc.go`) rather than through loom:

    - browser → `{"type": "offer", "sdp": …}`, passed to the device as
      `forward_rtc`; its answer comes back as `{"type": "answer", "sdp": …}`
    - browser → `{"type": "touch"}` while the user works the screen, since
      loom no longer sees their keys; it restarts the idle clock
    - browser → `{"type": "fallback"}`: the channel didn't open, so open the
      port the usual way and carry the bytes here after all
    - → browser `{"type": "error", "message": …}` when the device can't; the
      browser then falls back

  Only while Settings has P2P on (`Loom.P2P`); otherwise an offer is answered
  with an error and the browser falls back. A direct channel lives only as
  long as the page and this socket, and leaves nothing open behind it.

  The socket stays open alongside the data channel: closing it, or the switch
  going off, cancels the forward on the device either way.
  """
  @behaviour WebSock

  require Logger

  # A device whose loom-node predates forwarding ignores the request.
  @open_timeout :timer.seconds(10)
  # How often the user's input restarts the idle clock, at most.
  @touch_every :timer.seconds(60)

  @impl true
  def init(%{node_id: node_id, node_name: name, port: port, channel: channel, ip: ip} = args) do
    id = "fw_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Phoenix.PubSub.subscribe(Loom.PubSub, "forwards")
    Process.monitor(channel)
    rtc = Map.get(args, :rtc, false)
    p2p = Map.get(args, :p2p, true)
    Logger.info("Forward #{id}: #{ip} → #{name}:#{port}#{if rtc, do: " (peer to peer)"}")

    s = %{
      id: id,
      node_id: node_id,
      name: name,
      port: port,
      channel: channel,
      open: false,
      rtc: rtc,
      p2p: p2p,
      timer: nil,
      pending: [],
      touched: 0
    }

    {:ok, if(rtc, do: s, else: open(s))}
  end

  defp open(s) do
    send(s.channel, {:node_send, self(), s.id, "forward_open", %{"port" => s.port}})
    %{s | rtc: false, timer: Process.send_after(self(), :open_timeout, @open_timeout)}
  end

  # Input before the device has opened the port waits, in order.
  @impl true
  def handle_in({data, opcode: :binary}, %{open: false} = s),
    do: {:ok, %{s | pending: [data | s.pending]}}

  def handle_in({data, opcode: :binary}, s) do
    send_in(s, data)
    {:ok, touch(s, data)}
  end

  def handle_in({text, opcode: :text}, %{rtc: true} = s) do
    case Jason.decode(text) do
      {:ok, %{"type" => "offer", "sdp" => sdp}} when is_binary(sdp) and s.p2p ->
        send(
          s.channel,
          {:node_send, self(), s.id, "forward_rtc", %{"port" => s.port, "data" => sdp}}
        )

        {:ok, s}

      {:ok, %{"type" => "offer"}} ->
        {:push, {:text, Jason.encode!(%{type: "error", message: "P2P is off in Settings"})}, s}

      {:ok, %{"type" => "touch"}} ->
        {:ok, touch(s, <<4>>)}

      {:ok, %{"type" => "fallback"}} ->
        Logger.info("Forward #{s.id}: no peer-to-peer channel, relaying")
        {:ok, open(s)}

      _ ->
        {:ok, s}
    end
  end

  def handle_in(_text, s), do: {:ok, s}

  @impl true
  def handle_info({:node_reply, id, "forward_opened", _}, %{id: id} = s) do
    Process.cancel_timer(s.timer)
    s.pending |> Enum.reverse() |> Enum.each(&send_in(s, &1))
    {:ok, %{s | open: true, pending: []}}
  end

  def handle_info({:node_reply, id, "forward_rtc_answer", %{"data" => sdp}}, %{id: id, rtc: true} = s),
    do: {:push, {:text, Jason.encode!(%{type: "answer", sdp: sdp})}, s}

  # Before falling back, a device's refusal is for the browser to weigh.
  def handle_info({:node_reply, id, "error", %{"message" => message}}, %{id: id, rtc: true} = s),
    do: {:push, {:text, Jason.encode!(%{type: "error", message: message})}, s}

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
