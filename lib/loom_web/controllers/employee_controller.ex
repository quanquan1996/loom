defmodule LoomWeb.EmployeeController do
  @moduledoc """
  Virtual employees (`Loom.Employees`), for their page: hiring and settings,
  pause and wake, the day's budget, KPIs, and the reports they write.
  """
  use LoomWeb, :controller

  alias Loom.Employees

  # GET /api/employees
  def index(conn, _params), do: json(conn, %{employees: Employees.list()})

  # GET /api/employees/:id
  def show(conn, %{"id" => id}), do: reply(conn, Employees.get(id))

  # POST /api/employees — `name`, and any of the settings.
  def create(conn, params), do: reply(conn, Employees.create(params))

  # PATCH /api/employees/:id — any of the settings.
  def update(conn, %{"id" => id} = params),
    do: reply(conn, Employees.update(id, Map.delete(params, "id")))

  # DELETE /api/employees/:id
  def delete(conn, %{"id" => id}) do
    case Employees.delete(id) do
      :ok -> send_resp(conn, :no_content, "")
      error -> reply(conn, error)
    end
  end

  # POST /api/employees/:id/pause — `paused`: true or false.
  def pause(conn, %{"id" => id} = params),
    do: reply(conn, Employees.pause(id, params["paused"] == true))

  # POST /api/employees/:id/wake — an optional `note` goes with it.
  def wake(conn, %{"id" => id} = params), do: reply(conn, Employees.wake(id, params["note"]))

  # POST /api/employees/:id/seen — what it reported has been read.
  def seen(conn, %{"id" => id}), do: reply(conn, Employees.seen(id))

  # POST /api/employees/:id/approve — `usd` more, for today.
  def approve(conn, %{"id" => id} = params), do: reply(conn, Employees.approve(id, params["usd"]))

  # POST /api/employees/:id/kpis
  def add_kpi(conn, %{"id" => id} = params),
    do: reply(conn, Employees.add_kpi(id, Map.delete(params, "id")))

  # PATCH /api/employees/:id/kpis/:kpi
  def update_kpi(conn, %{"id" => id, "kpi" => kpi} = params),
    do: reply(conn, Employees.update_kpi(id, kpi, Map.drop(params, ["id", "kpi"])))

  # DELETE /api/employees/:id/kpis/:kpi
  def delete_kpi(conn, %{"id" => id, "kpi" => kpi}),
    do: reply(conn, Employees.delete_kpi(id, kpi))

  # POST /api/employees/:id/kpis/:kpi/review — `accept`, and a `note`.
  def review_kpi(conn, %{"id" => id, "kpi" => kpi} = params),
    do: reply(conn, Employees.review_kpi(id, kpi, params["accept"] == true, params["note"]))

  # GET /api/employees/:id/reports
  def reports(conn, %{"id" => id}) do
    case Employees.get(id) do
      {:ok, _} -> json(conn, %{reports: Employees.reports(id)})
      error -> reply(conn, error)
    end
  end

  # GET /api/employees/:id/reports/:file
  def report(conn, %{"id" => id, "file" => file}) do
    with {:ok, _} <- Employees.get(id),
         {:ok, text} <- Employees.report(id, file) do
      json(conn, %{file: file, text: text})
    else
      {:error, :enoent} -> conn |> put_status(:not_found) |> json(%{error: "no such report"})
      error -> reply(conn, error)
    end
  end

  defp reply(conn, {:ok, employee}), do: json(conn, %{employee: employee})

  defp reply(conn, {:error, :not_found}),
    do: conn |> put_status(:not_found) |> json(%{error: "no such employee"})

  defp reply(conn, {:error, reason}) when is_binary(reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: reason})

  defp reply(conn, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
end
