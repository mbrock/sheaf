defmodule Mix.Tasks.Sheaf.IngestFiles do
  @moduledoc """
  Ingests local files into the Sheaf blob store as RDF `ComputerFile` entities.
  """

  use Mix.Task

  @shortdoc "Ingests files into the Sheaf blob store"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          recursive: :boolean,
          no_backup: :boolean,
          dry_run: :boolean,
          extensions: :string
        ]
      )

    cond do
      invalid != [] ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")

      paths == [] ->
        Mix.raise(
          "Usage: mix sheaf.ingest_files PATH... [--recursive] [--extensions pdf,docx] [--dry-run] [--no-backup]"
        )

      true ->
        files = files(paths, opts)

        if files == [] do
          Mix.shell().info("No files to ingest.")
        else
          unless opts[:no_backup] || opts[:dry_run], do: Mix.Task.run("sheaf.backup")
          ingest!(files, opts)
        end
    end
  end

  defp ingest!(files, opts) do
    Mix.shell().info(
      "#{if opts[:dry_run], do: "Would ingest", else: "Ingesting"} #{length(files)} files"
    )

    results =
      Enum.map(files, fn path ->
        case ingest_file(path, opts) do
          {:ok, result} ->
            print_result(path, result, opts)
            {:ok, result}

          {:error, reason} ->
            Mix.shell().error("ERROR #{path}: #{inspect(reason)}")
            {:error, {path, reason}}
        end
      end)

    created = Enum.count(results, &match?({:ok, %{created?: true}}, &1))
    existing = Enum.count(results, &match?({:ok, %{created?: false}}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("Done. Created #{created}, existing #{existing}, errors #{errors}.")

    if errors > 0, do: Mix.raise("Some files failed to ingest.")
  end

  defp ingest_file(path, opts) do
    if opts[:dry_run] do
      with {:ok, hash} <- Sheaf.BlobStore.sha256(path),
           {:ok, existing_iri} <- Sheaf.Files.find_by_hash(hash) do
        {:ok, %{iri: existing_iri, hash: hash, created?: is_nil(existing_iri)}}
      end
    else
      Sheaf.Files.ingest(path)
    end
  end

  defp print_result(path, %{created?: created?, iri: iri} = result, opts) do
    status =
      cond do
        opts[:dry_run] && created? -> "would create"
        opts[:dry_run] -> "exists"
        created? -> "created"
        true -> "exists"
      end

    hash =
      case result do
        %{stored_file: %{hash: hash}} -> hash
        %{hash: hash} -> hash
        _ -> nil
      end

    iri = iri || "(new)"
    hash_info = if hash, do: " sha256:#{hash}", else: ""

    Mix.shell().info("#{status} #{iri}#{hash_info} #{path}")
  end

  defp files(paths, opts) do
    extensions = extensions(opts)

    paths
    |> Enum.flat_map(&expand_path(&1, opts))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&hidden?/1)
    |> Enum.filter(&extension_match?(&1, extensions))
    |> Enum.sort()
  end

  defp expand_path(path, opts) do
    path = Path.expand(path)

    cond do
      File.dir?(path) && opts[:recursive] ->
        Path.wildcard(Path.join([path, "**", "*"]))

      File.dir?(path) ->
        Path.wildcard(Path.join(path, "*"))

      true ->
        Path.wildcard(path)
    end
  end

  defp extensions(opts) do
    case Keyword.get(opts, :extensions) do
      nil ->
        :all

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim_leading(&1, "."))
        |> Enum.map(&String.downcase/1)
        |> MapSet.new()
    end
  end

  defp extension_match?(_path, :all), do: true

  defp extension_match?(path, extensions) do
    extension =
      path
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    MapSet.member?(extensions, extension)
  end

  defp hidden?(path) do
    path
    |> Path.basename()
    |> String.starts_with?(".")
  end
end
