defmodule SheafWeb.ImageController do
  use SheafWeb, :controller

  @immutable_cache "public, max-age=31536000, immutable"

  def show(conn, %{"id" => id}) do
    case Sheaf.OpenAI.Images.fetch(id) do
      {:ok, image} ->
        serve(conn, image.path, image.mime_type, etag(image))

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Image not found")
    end
  end

  def cover(conn, %{"id" => id}) do
    with {:ok, image} <- Sheaf.OpenAI.Images.fetch(id),
         {:ok, variant} <- Sheaf.ImageVariants.cover(image) do
      serve(conn, variant.path, variant.mime_type, variant.etag)
    else
      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("Image not found")
    end
  end

  defp serve(conn, path, mime_type, etag) do
    conn =
      conn
      |> put_resp_content_type(mime_type)
      |> put_resp_header("cache-control", @immutable_cache)
      |> put_resp_header("etag", etag)

    if fresh?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      send_file(conn, :ok, path)
    end
  end

  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.any?(fn candidate ->
      candidate == etag or candidate == "W/" <> etag or candidate == "*"
    end)
  end

  defp etag(%{sha256: sha256}) when is_binary(sha256),
    do: ~s("sha256-#{sha256}")

  defp etag(image), do: ~s("image-#{image.image_id}")
end
