defmodule SheafWeb.PageController do
  use SheafWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
