defmodule Sheaf.Files do
  @moduledoc """
  RDF-backed files stored in the local blob store.
  """

  alias RDF.Description
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
    with {:ok, dataset} <- Sheaf.fetch_dataset() do
      graph =
        dataset
        |> RDF.Dataset.graphs()
        |> Enum.reduce(RDF.Graph.new(), fn source_graph, acc ->
          files =
            source_graph
            |> RDF.Graph.descriptions()
            |> Enum.filter(&file?/1)
            |> Enum.map(& &1.subject)
            |> MapSet.new()

          source_graph
          |> RDF.Graph.triples()
          |> Enum.reduce(acc, fn
            {subject, predicate, object} = triple, acc ->
              cond do
                MapSet.member?(files, subject) ->
                  RDF.Graph.add(acc, triple)

                predicate == Sheaf.NS.DOC.sourceFile() and MapSet.member?(files, object) ->
                  acc
                  |> RDF.Graph.add(triple)
                  |> add_document_label(source_graph, subject)

                true ->
                  acc
              end
          end)
        end)

      {:ok, graph}
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
         filename when is_binary(filename) <- first_value(file, Sheaf.NS.DOC.originalFilename()) do
      {:ok, BlobStore.path_for(hash, filename, blob_opts(Keyword.put(opts, :filename, filename)))}
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
      @prefix RDF.NS.RDFS

      file
      |> a(FABIO.ComputerFile)
      |> a(PROV.Entity)
      |> RDFS.label(stored.original_filename)
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
    Description.include?(description, {RDF.type(), Sheaf.NS.FABIO.ComputerFile})
  end

  defp add_document_label(graph, source_graph, document) do
    case RDF.Graph.description(source_graph, document) do
      nil ->
        graph

      description ->
        case Description.first(description, RDF.NS.RDFS.label()) do
          nil -> graph
          label -> RDF.Graph.add(graph, {document, RDF.NS.RDFS.label(), label})
        end
    end
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
