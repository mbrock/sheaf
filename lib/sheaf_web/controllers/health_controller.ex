defmodule SheafWeb.HealthController do
  @moduledoc """
  Readiness endpoint used by local service scripts and reverse proxies.
  """

  use SheafWeb, :controller

  def show(conn, _params) do
    if Sheaf.Readiness.ready?() do
      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "starting"})
    end
  end
end
