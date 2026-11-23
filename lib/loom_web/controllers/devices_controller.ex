defmodule LoomWeb.DevicesController do
  @moduledoc """
  The Devices dialog's API: register, rename and remove the machines in
  `Loom.Nodes`. The list itself, and who is online, arrive over the lobby
  channel; these answer only so the dialog can show the result at once.

  Registering a device, or asking to reinstall one, returns an install `code`.
  The dialog turns it into `curl -fsSL <origin>/node/install/<code> | sh`; see
  `LoomWeb.NodeInstallController`.
  """
  use LoomWeb, :controller

  require Logger

  alias Loom.Nodes

  def index(conn, _params), do: json(conn, %{nodes: Nodes.list()})

  def create(conn, params) do
    case Nodes.create(params["name"], params["icon"]) do
      {:ok, node, code} -> conn |> put_status(201) |> json(%{node: node, code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id, "forward_port" => port}) do
    with {:ok, port} <- port_number(port),
         {:ok, node} <- Nodes.set_forward_port(id, port) do
      json(conn, %{node: node})
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id, "p2p" => on}) when is_boolean(on) do
    case Nodes.set_p2p(id, on) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Nodes.rename(id, params["name"]) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Nodes.delete(id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def install(conn, %{"id" => id}) do
    case Nodes.install_code(id) do
      {:ok, code} -> json(conn, %{code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "Switch port forwarding on (`port`, 5900 unless given) or off; see `Loom.Nodes`."
  def forward_on(conn, %{"id" => id} = params) do
    port = Map.get(params, "port") || remembered_port(id)

    with {:ok, port} <- port_number(port),
         {:ok, node} <- Nodes.forward_on(id, port) do
      Logger.info(
        "Devices: #{LoomWeb.ClientAddress.of(conn)} switched forwarding on for #{node.name}:#{port}"
      )

      json(conn, %{node: node})
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def forward_off(conn, %{"id" => id}) do
    case Nodes.forward_off(id) do
      {:ok, node} ->
        Logger.info(
          "Devices: #{LoomWeb.ClientAddress.of(conn)} switched forwarding off for #{node.name}"
        )

        json(conn, %{node: node})

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp remembered_port(id) do
    Enum.find_value(Nodes.list(), 5900, &(&1.id == id && &1.forward_port))
  end

  defp port_number(port) when is_integer(port), do: {:ok, port}

  defp port_number(port) when is_binary(port) do
    case Integer.parse(port) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "a port is a number from 1 to 65535"}
    end
  end

  defp port_number(_), do: {:error, "a port is a number from 1 to 65535"}

  defp refuse(conn, :not_found), do: conn |> put_status(404) |> json(%{error: "no such device"})
  defp refuse(conn, reason), do: conn |> put_status(422) |> json(%{error: reason})
end
