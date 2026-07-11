defmodule SheafWeb.ImageController do
  use SheafWeb, :controller

  def show(conn, %{"id" => id}) do
    case Sheaf.OpenAI.Images.fetch(id) do
      {:ok, image} ->
        conn
        |> put_resp_content_type(image.mime_type)
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_file(200, image.path)

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Image not found")
    end
  end
end
