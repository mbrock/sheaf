defmodule SheafWeb.SchemaController do
  @moduledoc """
  Serves the tracked Sheaf RDF schema as Turtle.
  """

  use SheafWeb, :controller

  def show(conn, _params) do
    schema_path = Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")

    conn
    |> put_resp_content_type("text/turtle", "utf-8")
    |> send_file(200, schema_path)
  end
end
