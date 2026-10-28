defmodule LoomWeb.NodeInstallController do
  @moduledoc """
  What a device fetches to join: `GET /node/install/:code` is a shell script,
  meant for `curl -fsSL … | sh`, `GET /node/install/:code/ps1` is the same in
  PowerShell for Windows, meant for `irm … | iex`, and
  `GET /node/download/:target` is the `loom-node` binary either downloads.

  The script is the only place a device's token is ever shown. Fetching it
  redeems the one-time code (`Loom.Nodes.redeem/1`), which mints a fresh token
  and kills the old one — so a second fetch of the same link gets nothing, and
  reinstalling a device is how its token is replaced.

  The binaries are not secret: they are built into `priv/node/` by
  `rel/deploy.sh` (`make -C node`) and carry no credentials.
  """
  use LoomWeb, :controller

  @targets ~w(darwin-arm64 darwin-amd64 linux-arm64 linux-amd64 windows-arm64 windows-amd64)

  @used_up "this install link is used up or expired; make a new one in Devices"

  def script(conn, %{"code" => code}) do
    case Loom.Nodes.redeem(code) do
      {:ok, node, token} ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, script(origin(conn), node.name, token))

      {:error, :invalid_code} ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(404, """
        #!/bin/sh
        echo "loom-node: #{@used_up}" >&2
        exit 1
        """)
    end
  end

  # text/plain, so `irm` hands `iex` a string.
  def powershell(conn, %{"code" => code}) do
    case Loom.Nodes.redeem(code) do
      {:ok, node, token} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, powershell(origin(conn), node.name, token))

      {:error, :invalid_code} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Write-Error 'loom-node: #{@used_up}'\n")
    end
  end

  def download(conn, %{"target" => target}) when target in @targets do
    path = Application.app_dir(:loom, "priv/node/loom-node-#{target}")

    if File.regular?(path) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "loom-node for #{target} was not built\n")
    end
  end

  def download(conn, _params), do: send_resp(conn, 404, "no such target\n")

  # The origin the device reached us on, which is the one it should keep
  # dialling. Cloudflare terminates TLS, so the scheme is in the header.
  defp origin(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [scheme | _] ->
        "#{scheme}://#{conn.host}"

      [] ->
        default? = {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}]
        "#{conn.scheme}://#{conn.host}#{if default?, do: "", else: ":#{conn.port}"}"
    end
  end

  defp script(origin, name, token) do
    """
    #!/bin/sh
    # Installs loom-node for "#{name}" on #{origin}. The token below is this
    # device's own; the link that printed it no longer works.
    set -eu

    URL='#{origin}'
    TOKEN='#{token}'

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
      darwin|linux) ;;
      mingw*|msys*|cygwin*)
        echo "loom-node: on Windows, make a new install command in Devices and run its PowerShell line" >&2
        exit 1 ;;
      *) echo "loom-node: $os is not supported" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64) arch=amd64 ;;
      arm64|aarch64) arch=arm64 ;;
      *) echo "loom-node: $(uname -m) is not supported" >&2; exit 1 ;;
    esac

    bin="$HOME/.local/bin"
    mkdir -p "$bin"
    tmp="$bin/.loom-node.$$"
    trap 'rm -f "$tmp"' EXIT
    echo "downloading loom-node for $os-$arch"
    curl -fsSL "$URL/node/download/$os-$arch" -o "$tmp"
    chmod 755 "$tmp"
    mv "$tmp" "$bin/loom-node"

    "$bin/loom-node" install --url "$URL" --token "$TOKEN" --shell "${SHELL:-/bin/sh}"
    """
  end

  # Run by `iex` inside the user's own PowerShell, so it must not `exit`: that
  # would close their window. A script block, so `throw` stops it instead.
  defp powershell(origin, name, token) do
    """
    # Installs loom-node for "#{name}" on #{origin}. The token below is this
    # device's own; the link that printed it no longer works.
    & {
      $ErrorActionPreference = 'Stop'
      $ProgressPreference = 'SilentlyContinue'

      $URL = '#{origin}'
      $TOKEN = '#{token}'

      $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
      switch ($cpu) {
        'AMD64' { $arch = 'amd64' }
        'ARM64' { $arch = 'arm64' }
        default { throw "loom-node: $cpu is not supported" }
      }

      $dir = Join-Path $env:LOCALAPPDATA 'loom-node'
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $exe = Join-Path $dir 'loom-node.exe'
      $tmp = Join-Path $dir ".loom-node.$PID.exe"
      Write-Host "downloading loom-node for windows-$arch"
      try {
        Invoke-WebRequest -UseBasicParsing -Uri "$URL/node/download/windows-$arch" -OutFile $tmp
        Move-Item -Force $tmp $exe
      } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp
      }

      & $exe install --url $URL --token $TOKEN
      if ($LASTEXITCODE -ne 0) { throw "loom-node: install failed" }
    }
    """
  end
end
