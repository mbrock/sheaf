defmodule Sheaf.Files do
  @moduledoc """
  RDF-backed files stored in the local blob store.
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.BlobStore
  require RDF.Graph

  @doc """
  Lists stored `fabio:ComputerFile` descriptions from all named graphs.
  """
  def list do
    with {:ok, graph} <- list_graph() do
      {:ok, descriptions(graph)}
    end
  end

  @doc """
  Returns a graph describing stored `fabio:ComputerFile` resources.
  """
  def list_graph do
    with {:ok, type_rows} <-
           Sheaf.Repo.match_rows(
             {nil, RDF.type(), RDF.iri(Sheaf.NS.FABIO.ComputerFile), nil}
           ) do
      files =
        type_rows |> Enum.map(fn {_g, s, _p, _o} -> s end) |> Enum.uniq()

      with {:ok, file_rows} <- rows_for({files, nil, nil, nil}),
           {:ok, source_rows} <-
             rows_for({nil, Sheaf.NS.DOC.sourceFile(), files, nil}),
           docs =
             source_rows
             |> Enum.map(fn {_g, s, _p, _o} -> s end)
             |> Enum.uniq(),
           {:ok, label_rows} <- rows_for({docs, RDFS.label(), nil, nil}) do
        {:ok, rows_graph(file_rows ++ source_rows ++ label_rows)}
      end
    end
  end

  @doc """
  Returns file descriptions from RDF data, newest first.
  """
  def descriptions(data) do
    data
    |> RDF.Data.descriptions()
    |> Enum.filter(&file?/1)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  @doc """
  Stores a local file in the blob store and persists a standalone RDF file graph.
  """
  def create(path, opts \\ []) when is_binary(path) do
    with {:ok, stored_file} <- BlobStore.put_file(path, blob_opts(opts)),
         file_iri = Keyword.get_lazy(opts, :file_iri, &Sheaf.mint/0),
         activity_iri = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0),
         generated_at = Keyword.get_lazy(opts, :generated_at, &now/0),
         graph = file_graph(file_iri, activity_iri, stored_file, generated_at),
         put_graph = Keyword.get(opts, :put_graph, &Sheaf.put_graph/2),
         :ok <- put_graph.(file_iri, graph) do
      {:ok, file_iri}
    end
  end

  @doc """
  Stores a local file unless a `ComputerFile` with the same SHA-256 already exists.

  Returns a map with the file IRI, blob metadata, and whether a new RDF graph was
  created. This is intended for batch ingestion where reruns should be safe.
  """
  def ingest(path, opts \\ []) when is_binary(path) do
    with {:ok, stored_file} <- BlobStore.put_file(path, blob_opts(opts)),
         {:ok, existing_iri} <- find_by_hash(stored_file.hash, opts) do
      case existing_iri do
        nil ->
          with {:ok, file_iri} <- create_from_stored_file(stored_file, opts) do
            {:ok, %{iri: file_iri, stored_file: stored_file, created?: true}}
          end

        file_iri ->
          {:ok, %{iri: file_iri, stored_file: stored_file, created?: false}}
      end
    end
  end

  @doc """
  Finds the first known `ComputerFile` IRI with a matching SHA-256 hash.
  """
  def find_by_hash(hash, opts \\ []) when is_binary(hash) do
    with {:ok, graph} <- files_graph(opts) do
      iri =
        graph
        |> descriptions()
        |> Enum.find_value(fn description ->
          if first_value(description, Sheaf.NS.DOC.sha256()) == hash do
            description.subject
          end
        end)

      {:ok, iri}
    end
  end

  @doc """
  Resolves a `ComputerFile` description to its content-addressed local blob path.
  """
  def local_path(%Description{} = file, opts \\ []) do
    with hash when is_binary(hash) <- first_value(file, Sheaf.NS.DOC.sha256()),
         filename when is_binary(filename) <-
           first_value(file, Sheaf.NS.DOC.originalFilename()) do
      {:ok,
       BlobStore.path_for(
         hash,
         filename,
         blob_opts(Keyword.put(opts, :filename, filename))
       )}
    else
      _ -> {:error, :missing_blob_metadata}
    end
  end

  defp files_graph(opts) do
    case Keyword.fetch(opts, :files_graph) do
      {:ok, graph} -> {:ok, graph}
      :error -> list_graph()
    end
  end

  defp create_from_stored_file(stored_file, opts) do
    file_iri = Keyword.get_lazy(opts, :file_iri, &Sheaf.mint/0)
    activity_iri = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    graph = file_graph(file_iri, activity_iri, stored_file, generated_at)
    put_graph = Keyword.get(opts, :put_graph, &Sheaf.put_graph/2)

    with :ok <- put_graph.(file_iri, graph) do
      {:ok, file_iri}
    end
  end

  defp file_graph(file_iri, activity_iri, stored_file, generated_at) do
    RDF.Graph.build file: file_iri,
                    activity: activity_iri,
                    stored: stored_file,
                    generated_at: generated_at do
      @prefix Sheaf.NS.DOC
      @prefix Sheaf.NS.FABIO
      @prefix Sheaf.NS.PROV

      file
      |> a(FABIO.ComputerFile)
      |> a(PROV.Entity)
      |> RDF.NS.RDFS.label(stored.original_filename)
      |> DOC.sha256(stored.hash)
      |> DOC.sourceKey(stored.storage_key)
      |> DOC.mimeType(stored.mime_type)
      |> DOC.byteSize(stored.byte_size)
      |> DOC.originalFilename(stored.original_filename)
      |> PROV.wasGeneratedBy(activity)
      |> PROV.generatedAtTime(generated_at)

      activity
      |> a(PROV.Activity)
      |> RDFS.label("File upload")
    end
  end

  defp file?(%Description{} = description) do
    Description.include?(
      description,
      {RDF.type(), Sheaf.NS.FABIO.ComputerFile}
    )
  end

  defp rows_for({[], _predicate, _object, _graph}), do: {:ok, []}
  defp rows_for({_subject, _predicate, [], _graph}), do: {:ok, []}
  defp rows_for(pattern), do: Sheaf.Repo.match_rows(pattern)

  defp rows_graph(rows) do
    Enum.reduce(rows, Graph.new(), fn {_graph, subject, predicate, object},
                                      graph ->
      Graph.add(graph, {subject, predicate, object})
    end)
  end

  defp blob_opts(opts) do
    opts
    |> Keyword.take([:blob_root, :filename, :mime_type])
    |> Keyword.new(fn
      {:blob_root, root} -> {:root, root}
      other -> other
    end)
  end

  defp sort_key(%Description{} = file) do
    file
    |> Description.first(Sheaf.NS.PROV.generatedAtTime())
    |> term_value()
    |> case do
      %DateTime{} = generated_at -> DateTime.to_unix(generated_at)
      nil -> 0
      generated_at -> to_string(generated_at)
    end
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: RDF.Term.value(term)

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> term_value()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
