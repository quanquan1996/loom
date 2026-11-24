defmodule Loom.WhereaboutsTest do
  use ExUnit.Case, async: true

  alias Loom.Whereabouts

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
  @mac_edge "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0"
  @win_edge "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0"

  @devices [
    %{name: "MacMiniM6", os: "darwin", ip: "2408:8256:c84:6ac4:ec68:57d9:8c22:5db3"},
    %{name: "HomeWindows", os: "windows", ip: "112.94.214.61"},
    %{name: "WorkM3Pro", os: "darwin", ip: "129.227.114.171"}
  ]
  @home ["MacMiniM6", "HomeWindows"]

  test "an iPhone on the home Wi-Fi, matched by the IPv6 /64" do
    line = Whereabouts.describe("2408:8256:c84:6ac4:1:2:3:4", @iphone, @devices, @home)
    assert line =~ "from iPhone · Safari, at home; on the same network as MacMiniM6."
  end

  test "the PC at home, matched by the IPv4 address and the OS" do
    line = Whereabouts.describe("112.94.214.61", @win_edge, @devices, @home)
    assert line =~ "probably on HomeWindows (same network and OS); at home."
  end

  test "the work Mac away from home" do
    line = Whereabouts.describe("129.227.114.171", @mac_edge, @devices, @home)
    assert line =~ "probably on WorkM3Pro (same network and OS); not at home."
  end

  test "a phone on mobile data" do
    line = Whereabouts.describe("2408:8459:610:45ed::1", @iphone, @devices, @home)
    assert line =~ "from iPhone · Safari, not at home."
  end

  test "no home configured says nothing about home" do
    line = Whereabouts.describe("2408:8459:610:45ed::1", @iphone, @devices, [])
    assert line =~ "from iPhone · Safari."
    refute line =~ "home"
  end

  test "no address, no line" do
    assert Whereabouts.describe(nil, @iphone, @devices, @home) == nil
  end
end
