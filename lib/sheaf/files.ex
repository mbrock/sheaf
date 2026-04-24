defmodule Sheaf.Files do
  @moduledoc """
  RDF-backed files stored in the local blob store.
  """

  alias Sheaf.BlobStore
  alias Sheaf.Id
  require RDF.Graph

  @query """
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX prov: <http://www.w3.org/ns/prov#>
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?graph ?file ?label ?hash ?key ?mime ?bytes ?name ?generatedAt ?document ?documentLabel WHERE {
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
  ORDER BY DESC(?generatedAt) ?name ?label
  """

  @type file :: %{
          id: String.t(),
          iri: String.t(),
          graph: String.t(),
          filename: String.t() | nil,
          label: String.t() | nil,
          sha256: String.t() | nil,
          source_key: String.t() | nil,
          mime_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          generated_at: String.t() | nil,
          document: map() | nil,
          standalone?: boolean()
        }

  @doc """
  Lists stored `fabio:ComputerFile` resources from all named graphs.
  """
  @spec list() :: {:ok, [file()]} | {:error, term()}
  def list do
    with {:ok, result} <- Sheaf.select(@query) do
      {:ok, from_rows(result.results)}
    end
  end

  @doc """
  Stores a local file in the blob store and persists a standalone RDF file graph.
  """
  @spec create(Path.t(), keyword()) :: {:ok, file()} | {:error, term()}
  def create(path, opts \\ []) when is_binary(path) do
    with {:ok, stored_file} <- BlobStore.put_file(path, blob_opts(opts)),
         file_iri = Keyword.get_lazy(opts, :file_iri, &Sheaf.mint/0),
         activity_iri = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0),
         generated_at = Keyword.get_lazy(opts, :generated_at, &now/0),
         graph = file_graph(file_iri, activity_iri, stored_file, generated_at),
         put_graph = Keyword.get(opts, :put_graph, &Sheaf.put_graph/2),
         :ok <- put_graph.(file_iri, graph) do
      {:ok, file_from_stored(file_iri, stored_file, generated_at)}
    end
  end

  @doc false
  def from_rows(rows) do
    rows
    |> Enum.group_by(&row_value(&1, "file"))
    |> Enum.reject(fn {iri, _rows} -> is_nil(iri) end)
    |> Enum.map(fn {iri, rows} -> file_from_rows(iri, rows) end)
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

  defp file_from_rows(iri, [row | _] = rows) do
    graph = row_value(row, "graph")
    document_iri = row_value(row, "document")

    %{
      id: Id.id_from_iri(iri),
      iri: iri,
      graph: graph,
      label: value(rows, "label"),
      filename: value(rows, "name") || value(rows, "label"),
      sha256: value(rows, "hash"),
      source_key: value(rows, "key"),
      mime_type: value(rows, "mime"),
      byte_size: integer_value(rows, "bytes"),
      generated_at: value(rows, "generatedAt"),
      document: document(document_iri, row_value(row, "documentLabel")),
      standalone?: graph == iri
    }
  end

  defp file_from_stored(file_iri, stored_file, generated_at) do
    %{
      id: Id.id_from_iri(file_iri),
      iri: to_string(file_iri),
      graph: to_string(file_iri),
      label: stored_file.original_filename,
      filename: stored_file.original_filename,
      sha256: stored_file.hash,
      source_key: stored_file.storage_key,
      mime_type: stored_file.mime_type,
      byte_size: stored_file.byte_size,
      generated_at: DateTime.to_iso8601(generated_at),
      document: nil,
      standalone?: true
    }
  end

  defp document(nil, _label), do: nil

  defp document(iri, label) do
    %{id: Id.id_from_iri(iri), iri: iri, title: label}
  end

  defp blob_opts(opts) do
    opts
    |> Keyword.take([:blob_root, :filename, :mime_type])
    |> Keyword.new(fn
      {:blob_root, root} -> {:root, root}
      other -> other
    end)
  end

  defp integer_value(rows, key) do
    case value(rows, key) do
      nil ->
        nil

      string ->
        case Integer.parse(string) do
          {int, _rest} -> int
          :error -> nil
        end
    end
  end

  defp value(rows, key) do
    rows
    |> Enum.find_value(&row_value(&1, key))
  end

  defp row_value(row, key) do
    row
    |> Map.get(key)
    |> term_value()
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    term
    |> RDF.Term.value()
    |> case do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> to_string(value)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
