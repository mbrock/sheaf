defmodule Sheaf.Files do
  @moduledoc """
  RDF-backed files stored in the local blob store.
  """

  alias RDF.Description
  alias Sheaf.BlobStore
  require RDF.Graph

  @query """
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX prov: <http://www.w3.org/ns/prov#>
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  CONSTRUCT {
    ?file a fabio:ComputerFile ;
      rdfs:label ?label ;
      sheaf:sha256 ?hash ;
      sheaf:sourceKey ?key ;
      sheaf:mimeType ?mime ;
      sheaf:byteSize ?bytes ;
      sheaf:originalFilename ?name ;
      prov:generatedAtTime ?generatedAt .

    ?document sheaf:sourceFile ?file ;
      rdfs:label ?documentLabel .
  }
  WHERE {
    GRAPH ?graph {
      ?file a fabio:ComputerFile .
      OPTIONAL { ?file rdfs:label ?label }
      OPTIONAL { ?file sheaf:sha256 ?hash }
      OPTIONAL { ?file sheaf:sourceKey ?key }
      OPTIONAL { ?file sheaf:mimeType ?mime }
      OPTIONAL { ?file sheaf:byteSize ?bytes }
      OPTIONAL { ?file sheaf:originalFilename ?name }
      OPTIONAL { ?file prov:generatedAtTime ?generatedAt }
      OPTIONAL {
        ?document sheaf:sourceFile ?file .
        OPTIONAL { ?document rdfs:label ?documentLabel }
      }
    }
  }
  """

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
  def list_graph, do: Sheaf.query(@query)

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
