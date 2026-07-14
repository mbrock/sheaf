defmodule Sheaf.ImageVariants do
  @moduledoc "Builds and caches smaller delivery variants of stored images."

  require OpenTelemetry.Tracer, as: Tracer

  @cover_geometry "512x768>"
  @cover_quality "82"
  @cover_version "cover-v1"
  @cover_mime_type "image/webp"

  def cover(image, opts \\ []) when is_map(image) do
    path = image.path <> ".#{@cover_version}.webp"

    Tracer.with_span "sheaf.image.variant", %{
      attributes: [
        {"sheaf.image.id", image.image_id},
        {"sheaf.image.source_path", image.path},
        {"sheaf.image.variant", @cover_version},
        {"sheaf.image.variant_path", path},
        {"sheaf.image.geometry", @cover_geometry},
        {"sheaf.image.quality", @cover_quality}
      ]
    } do
      with {:ok, cache_hit?} <- ensure_cover(image.path, path, opts),
           {:ok, stat} <- File.stat(path) do
        Tracer.set_attributes([
          {"sheaf.image.variant.cache_hit", cache_hit?},
          {"sheaf.image.variant.byte_size", stat.size}
        ])

        {:ok,
         %{
           path: path,
           mime_type: @cover_mime_type,
           etag: etag(image.sha256, @cover_version),
           byte_size: stat.size
         }}
      end
    end
  end

  defp ensure_cover(source, destination, opts) do
    if File.regular?(destination) do
      {:ok, true}
    else
      generate_cover(source, destination, opts)
    end
  end

  defp generate_cover(source, destination, opts) do
    temporary =
      destination <>
        ".#{System.unique_integer([:positive, :monotonic])}.tmp.webp"

    convert = Keyword.get(opts, :convert, &convert/2)

    try do
      with :ok <- convert.(source, temporary),
           :ok <- File.rename(temporary, destination) do
        {:ok, false}
      end
    after
      File.rm(temporary)
    end
  end

  defp convert(source, destination) do
    case System.cmd(
           "convert",
           [
             source,
             "-auto-orient",
             "-thumbnail",
             @cover_geometry,
             "-strip",
             "-quality",
             @cover_quality,
             "webp:#{destination}"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:image_conversion_failed, status, output}}
    end
  rescue
    error in ErlangError ->
      {:error, {:image_conversion_failed, error.original}}
  end

  defp etag(sha256, variant) when is_binary(sha256),
    do: ~s("sha256-#{sha256}-#{variant}")

  defp etag(_sha256, variant), do: ~s("#{variant}")
end
