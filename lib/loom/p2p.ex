defmodule Loom.P2P do
  @moduledoc """
  Whether a device's screen may go peer to peer (`LoomWeb.ForwardSocket`,
  "Peer to peer"): one switch for the whole instance, in Settings, off until
  the user turns it on. Kept in `p2p.json` in Loom's directory.

  On, the VNC pane tries a direct WebRTC channel to the device first and
  falls back to loom's relay; off, it only relays. A direct channel lives as
  long as the page and its socket, so the switch opens nothing by itself.
  """

  @doc "Whether peer to peer is switched on."
  def on? do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"on" => on}} when is_boolean(on) <- Jason.decode(body) do
      on
    else
      _ -> false
    end
  end

  @doc "Switch it on or off."
  def put(on) when is_boolean(on) do
    tmp = path() <> ".tmp"
    File.mkdir_p!(Path.dirname(path()))
    File.write!(tmp, Jason.encode!(%{on: on}))
    File.rename!(tmp, path())
    :ok
  end

  defp path, do: Path.join(Loom.Agent.Store.home(), "p2p.json")
end
