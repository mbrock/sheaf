defmodule SheafWeb.CoverController do
  use SheafWeb, :controller

  def show(conn, %{"id" => id}) do
    case Sheaf.OpenAI.CoverImages.fetch(id) do
      {:ok, cover} ->
        conn
        |> put_resp_content_type(cover.mime_type)
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_file(200, cover.path)

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Cover not found")
    end
  end
end
