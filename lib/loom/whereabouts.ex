defmodule Loom.Whereabouts do
  @moduledoc """
  Where the user is writing from, told to the agent so it can judge what it
  can do itself and what needs the user's hands (a security-key touch, a
  login on the machine in front of them, a cable at home).

  Two signals, both from addresses Loom already sees:

    * the browser: its public address and User-Agent (`LoomWeb.UserSocket`);
    * the user's devices: the public address each `loom-node` connected from
      (`Loom.Nodes.addresses/0`).

  Same network means the same IPv4 address (one NAT) or the same IPv6 /64
  (one LAN). A device on that network running the browser's OS is probably
  the one the user sits at. "At home" means sharing a network with a device
  listed under `home` in `~/.loom/places.json`:

      {"home": ["MacMiniM6", "HomeWindows"]}

  Nothing is guessed beyond that: no address, no device, no home.
  """

  @doc """
  One line for the agent, or nil when there is nothing to say. `ua` is the
  browser's User-Agent.
  """
  @spec describe(String.t() | nil, String.t() | nil) :: String.t() | nil
  def describe(ip, ua) do
    devices = safe_addresses()
    describe(ip, ua, devices, home_names())
  end

  @doc false
  def describe(ip, ua, devices, home) do
    browser = LoomWeb.AuthController.device_name(ua || "")

    with ip when is_binary(ip) <- ip,
         {:ok, addr} <- :inet.parse_address(String.to_charlist(ip)) do
      near = for d <- devices, same_network?(addr, d.ip), do: d
      at_home = Enum.any?(near, &(&1.name in home))
      os = os_of(ua || "")
      at = for d <- near, os != nil and d.os == os, do: d.name

      place =
        cond do
          home == [] -> nil
          at_home -> "at home"
          true -> "not at home"
        end

      on =
        case at do
          [] -> nil
          [one] -> "probably on #{one} (same network and OS)"
          many -> "probably on one of #{Enum.join(many, ", ")} (same network and OS)"
        end

      others = for d <- near, d.name not in at, do: d.name

      network =
        if others != [], do: "on the same network as #{Enum.join(others, ", ")}"

      details = Enum.reject([on, place, network], &is_nil/1)

      "[Note from Loom, not written by the user: the user is writing from " <>
        browser <>
        if(details == [], do: "", else: ", " <> Enum.join(details, "; ")) <>
        ". Told again only when it changes.]"
    else
      _ -> nil
    end
  end

  defp safe_addresses do
    Loom.Nodes.addresses()
  catch
    :exit, _ -> []
  end

  defp home_names do
    path = Path.join(Loom.Agent.Store.home(), "places.json")

    with {:ok, body} <- File.read(path),
         {:ok, %{"home" => names}} when is_list(names) <- Jason.decode(body) do
      Enum.filter(names, &is_binary/1)
    else
      _ -> []
    end
  end

  # loom-node reports Go's GOOS.
  defp os_of(ua) do
    cond do
      ua =~ "iPhone" or ua =~ "iPad" -> "ios"
      ua =~ "Android" -> "android"
      ua =~ "Windows" -> "windows"
      ua =~ "Macintosh" -> "darwin"
      ua =~ "Linux" -> "linux"
      true -> nil
    end
  end

  defp same_network?(addr, other) when is_binary(other) do
    case :inet.parse_address(String.to_charlist(other)) do
      {:ok, o} -> same?(addr, o)
      _ -> false
    end
  end

  defp same_network?(_, _), do: false

  defp same?({_, _, _, _} = a, {_, _, _, _} = b), do: a == b

  defp same?({a1, a2, a3, a4, _, _, _, _}, {b1, b2, b3, b4, _, _, _, _}),
    do: {a1, a2, a3, a4} == {b1, b2, b3, b4}

  defp same?(_, _), do: false
end
