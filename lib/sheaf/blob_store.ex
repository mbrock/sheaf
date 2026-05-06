defmodule Sheaf.BlobStore do
  @moduledoc """
  Stores local files by content hash.
  """

  @default_root "priv/blobs"
  @chunk_size 2048

  @type stored_file :: %{
          byte_size: non_neg_integer(),
          hash: String.t(),
          mime_type: String.t(),
          original_filename: String.t(),
          path: Path.t(),
          source_path: Path.t(),
          storage_key: String.t()
        }

  @spec put_file(Path.t(), keyword()) ::
          {:ok, stored_file()} | {:error, term()}
  def put_file(source_path, opts \\ []) when is_binary(source_path) do
    with {:ok, stat} <- File.stat(source_path),
         {:ok, hash} <- sha256(source_path),
         destination = path_for(hash, source_path, opts),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- copy_file(source_path, destination, hash) do
      {:ok,
       %{
         byte_size: stat.size,
         hash: hash,
         mime_type: Keyword.get(opts, :mime_type, mime_type(source_path)),
         original_filename: original_filename(source_path, opts),
         path: destination,
         source_path: source_path,
         storage_key: "sha256:#{hash}"
       }}
    end
  end

  @spec sha256(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256(path) when is_binary(path) do
    hash =
      path
      |> File.stream!([], @chunk_size)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  rescue
    error in File.Error -> {:error, error.reason}
  end

  @spec path_for(String.t(), Path.t(), keyword()) :: Path.t()
  def path_for(hash, source_path, opts \\ [])
      when is_binary(hash) and is_binary(source_path) do
    extension =
      source_path
      |> original_filename(opts)
      |> Path.extname()
      |> String.downcase()

    Path.join([
      root(opts),
      "sha256",
      String.slice(hash, 0, 2),
      String.slice(hash, 2, 2),
      hash <> extension
    ])
  end

  defp copy_file(source_path, destination, hash) do
    if File.exists?(destination) do
      case sha256(destination) do
        {:ok, ^hash} -> :ok
        {:ok, _other_hash} -> {:error, {:blob_hash_mismatch, destination}}
        {:error, reason} -> {:error, reason}
      end
    else
      File.cp(source_path, destination)
    end
  end

  defp root(opts) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:root, @default_root)

    Keyword.get(opts, :root, configured)
  end

  defp original_filename(source_path, opts) do
    opts
    |> Keyword.get(:filename, Path.basename(source_path))
    |> to_string()
  end

  defp mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      _other -> "application/octet-stream"
    end
  end
end
