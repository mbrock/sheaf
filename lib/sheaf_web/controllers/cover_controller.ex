defmodule SheafWeb.CoverController do
  use SheafWeb, :controller

  def show(conn, %{"id" => id}) do
    with {:ok, image_id} <- Sheaf.DocumentMetadata.cover_image_id(id),
         {:ok, _image} <- Sheaf.OpenAI.Images.fetch(image_id) do
      redirect(conn, to: "/images/#{image_id}")
    else
      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Cover not found")
    end
  end
end
