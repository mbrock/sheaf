defmodule Sheaf.Embedding.Index do
  @moduledoc """
  Builds and queries Sheaf's derived SQLite embedding index.
  """

  require Logger

  alias RDF.{Description, Graph}
  alias Sheaf.Embedding.Store

  @default_dimensions 768
  @default_max_concurrency 8
  @valid_kinds ~w(paragraph sourceHtml row)

  @type text_unit :: %{
          required(:iri) => String.t(),
          required(:kind) => String.t(),
          required(:text) => String.t(),
          required(:text_hash) => String.t(),
          required(:text_chars) => non_neg_integer(),
          optional(:doc_iri) => String.t() | nil,
          optional(:doc_title) => String.t() | nil,
          optional(:source_page) => integer() | nil,
          optional(:spreadsheet_row) => integer() | nil,
          optional(:spreadsheet_source) => String.t() | nil,
          optional(:code_category_title) => String.t() | nil
        }

  @doc """
  Embeds missing or stale current RDF text units into SQLite.

  Existing matching embeddings from previous completed/partial runs are reused
  by lookup, not copied into the new run.
  """
  @spec sync(keyword()) :: {:ok, map()} | {:error, term()}
  def sync(opts \\ []) do
    model = Sheaf.Embedding.model(opts)
    dimensions = Keyword.get(opts, :output_dimensionality, @default_dimensions)
    run_iri = opts |> Keyword.get_lazy(:run_iri, fn -> Sheaf.mint() |> to_string() end)

    with {:ok, units} <- text_units(Keyword.put(opts, :model, model)),
         {:ok, conn} <- Store.open(opts) do
      try do
        sync_run(conn, run_iri, units, model, dimensions, opts)
      after
        Store.close(conn)
      end
    end
  end

  @doc """
  Returns current text-bearing RDF blocks.
  """
  @spec text_units(keyword()) :: {:ok, [text_unit()]} | {:error, term()}
  def text_units(opts \\ []) do
    select = Keyword.get(opts, :select, &Sheaf.select/1)

    case select.(text_units_sparql(opts)) do
      {:ok, result} ->
        model = Keyword.get(opts, :model, Sheaf.Embedding.model())
        dimensions = Keyword.get(opts, :output_dimensionality, @default_dimensions)

        units =
          result.results
          |> Enum.map(&unit_from_row(&1, model, dimensions))
          |> Enum.reject(&(&1.text == ""))

        {:ok, units}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def text_hash(text, model, dimensions) do
    :crypto.hash(:sha256, [model, <<0>>, Integer.to_string(dimensions), <<0>>, text])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Searches the current text-bearing corpus with the SQLite embedding index.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      model = Sheaf.Embedding.model(opts)
      dimensions = Keyword.get(opts, :output_dimensionality, @default_dimensions)
      limit = Keyword.get(opts, :limit, 8)

      candidate_limit = Keyword.get(opts, :candidate_limit, limit)

      with {:ok, query_embedding} <-
             Sheaf.Embedding.embed_text(
               query,
               Keyword.put(opts, :output_dimensionality, dimensions)
             ),
           {:ok, conn} <- Store.open(opts) do
        try do
          search_loaded(
            conn,
            query_embedding.values,
            model,
            dimensions,
            limit,
            candidate_limit,
            opts
          )
        after
          Store.close(conn)
        end
      end
    end
  end

  defp sync_run(conn, run_iri, units, model, dimensions, opts) do
    reusable = Store.reusable_hashes(conn, model, dimensions)

    {missing, skipped} =
      Enum.split_with(units, fn unit -> !MapSet.member?(reusable, {unit.iri, unit.text_hash}) end)

    metadata = %{
      kinds: Enum.frequencies_by(units, & &1.kind),
      limit: Keyword.get(opts, :limit),
      requested_kinds: Keyword.get(opts, :kinds)
    }

    with :ok <-
           Store.create_run(conn, %{
             iri: run_iri,
             model: model,
             dimensions: dimensions,
             target_count: length(units),
             skipped_count: length(skipped),
             metadata: metadata
           }) do
      Logger.info(
        "Embedding sync #{run_iri}: #{length(units)} current text units, #{length(skipped)} reusable, #{length(missing)} to embed"
      )

      stats = embed_missing(conn, run_iri, missing, dimensions, opts)
      status = if stats.errors == 0, do: "completed", else: "partial"

      finish_attrs = %{
        status: status,
        embedded_count: stats.embedded,
        skipped_count: length(skipped),
        error_count: stats.errors,
        metadata: Map.put(metadata, :errors, stats.error_details)
      }

      with :ok <- Store.finish_run(conn, run_iri, finish_attrs),
           {:ok, vector_count} <- Store.sync_vector_index(conn, model, dimensions) do
        Logger.info(
          "Embedding sync #{run_iri}: refreshed sqlite-vec index with #{vector_count} vectors"
        )

        {:ok,
         %{
           run_iri: run_iri,
           model: model,
           dimensions: dimensions,
           target_count: length(units),
           embedded_count: stats.embedded,
           skipped_count: length(skipped),
           error_count: stats.errors,
           status: status
         }}
      end
    end
  end

  defp embed_missing(_conn, _run_iri, [], _dimensions, _opts) do
    %{embedded: 0, errors: 0, error_details: []}
  end

  defp embed_missing(conn, run_iri, units, dimensions, opts) do
    total = length(units)
    concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    Logger.info(
      "Embedding sync #{run_iri}: starting #{total} requests with concurrency #{concurrency}"
    )

    units
    |> Task.async_stream(&embed_unit(&1, dimensions, opts),
      max_concurrency: concurrency,
      ordered: false,
      timeout: Keyword.get(opts, :timeout, :infinity)
    )
    |> Enum.reduce(%{embedded: 0, errors: 0, error_details: []}, fn result, stats ->
      case result do
        {:ok, {:ok, unit, embedding}} ->
          :ok =
            Store.insert_embedding(conn, %{
              iri: unit.iri,
              run_iri: run_iri,
              text_hash: unit.text_hash,
              text_chars: unit.text_chars,
              values: embedding.values
            })

          embedded = stats.embedded + 1

          if rem(embedded, 100) == 0 or embedded == total,
            do: Logger.info("Embedding sync #{run_iri}: stored #{embedded}/#{total}")

          %{stats | embedded: embedded}

        {:ok, {:error, unit, reason}} ->
          Logger.warning("Embedding sync #{run_iri}: failed #{unit.iri}: #{inspect(reason)}")

          %{
            stats
            | errors: stats.errors + 1,
              error_details: [%{iri: unit.iri, reason: inspect(reason)} | stats.error_details]
          }

        {:exit, reason} ->
          Logger.warning("Embedding sync #{run_iri}: task exited: #{inspect(reason)}")

          %{
            stats
            | errors: stats.errors + 1,
              error_details: [%{reason: inspect(reason)} | stats.error_details]
          }
      end
    end)
    |> Map.update!(:error_details, &Enum.reverse/1)
  end

  defp embed_unit(unit, dimensions, opts) do
    case Sheaf.Embedding.embed_text(
           unit.text,
           Keyword.put(opts, :output_dimensionality, dimensions)
         ) do
      {:ok, embedding} -> {:ok, unit, embedding}
      {:error, reason} -> {:error, unit, reason}
    end
  end

  defp text_units_sparql(opts) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()
    limit = Keyword.get(opts, :limit)

    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX prov: <http://www.w3.org/ns/prov#>

    SELECT ?iri ?kind ?text ?doc ?docTitle ?sourcePage ?spreadsheetRow ?spreadsheetSource ?codeCategoryTitle WHERE {
      GRAPH ?doc {
        OPTIONAL { ?doc <http://www.w3.org/2000/01/rdf-schema#label> ?docTitle }
        #{text_unit_unions(kinds)}
      }
    }
    ORDER BY ?iri
    #{if limit, do: "LIMIT #{limit}", else: ""}
    """
  end

  defp text_unit_unions(kinds) do
    [
      {"paragraph",
       """
       ?iri sheaf:paragraph ?para .
       ?para sheaf:text ?text .
       FILTER NOT EXISTS { ?para prov:wasInvalidatedBy ?_inv }
       BIND("paragraph" AS ?kind)
       """},
      {"sourceHtml",
       """
       ?iri sheaf:sourceHtml ?text .
       OPTIONAL { ?iri sheaf:sourcePage ?sourcePage }
       BIND("sourceHtml" AS ?kind)
       """},
      {"row",
       """
       ?iri a sheaf:Row ;
         sheaf:text ?text .
       OPTIONAL { ?iri sheaf:spreadsheetRow ?spreadsheetRow }
       OPTIONAL { ?iri sheaf:spreadsheetSource ?spreadsheetSource }
       OPTIONAL { ?iri sheaf:codeCategoryTitle ?codeCategoryTitle }
       BIND("row" AS ?kind)
       """}
    ]
    |> Enum.filter(fn {kind, _query} -> kind in kinds end)
    |> Enum.map(fn {_kind, query} -> "{\n#{String.trim(query)}\n}" end)
    |> Enum.join(" UNION ")
  end

  defp unit_from_row(row, model, dimensions) do
    text = row |> Map.fetch!("text") |> term_value()

    %{
      iri: row |> Map.fetch!("iri") |> term_value(),
      kind: row |> Map.fetch!("kind") |> term_value(),
      text: text,
      text_hash: text_hash(text, model, dimensions),
      text_chars: String.length(text),
      doc_iri: row |> Map.get("doc") |> term_value(),
      doc_title: row |> Map.get("docTitle") |> term_value(),
      source_page: row |> Map.get("sourcePage") |> integer_value(),
      spreadsheet_row: row |> Map.get("spreadsheetRow") |> integer_value(),
      spreadsheet_source: row |> Map.get("spreadsheetSource") |> term_value(),
      code_category_title: row |> Map.get("codeCategoryTitle") |> term_value()
    }
  end

  @doc false
  def metadata_for_iris(iris, opts \\ []), do: descriptions_for_iris(iris, opts)

  @doc false
  def descriptions_for_iris(iris, opts \\ [])

  def descriptions_for_iris([], _opts), do: {:ok, %{}}

  def descriptions_for_iris(iris, opts) when is_list(iris) do
    select = Keyword.get(opts, :select, &Sheaf.select/1)

    with {:ok, result} <- select.(descriptions_sparql(iris)),
         {:ok, titles} <- document_titles(opts) do
      graph = graph_from_description_rows(result.results)
      docs_by_iri = docs_by_iri(result.results)

      {:ok,
       iris
       |> Enum.uniq()
       |> Enum.map(&unit_from_graph(graph, &1, docs_by_iri, titles))
       |> Enum.reject(&is_nil/1)
       |> Map.new(&{&1.iri, &1})}
    end
  end

  @doc false
  def document_titles(opts \\ []) do
    select = Keyword.get(opts, :select, &Sheaf.select/1)

    case select.(document_titles_sparql()) do
      {:ok, result} ->
        {:ok,
         Map.new(result.results, fn row ->
           {row |> Map.fetch!("doc") |> term_value(), row |> Map.fetch!("title") |> term_value()}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_loaded(conn, query_values, model, dimensions, limit, candidate_limit, opts) do
    with {:ok, ranked} <-
           Store.search_vectors(conn, query_values, model, dimensions, candidate_limit) do
      with {:ok, metadata} <-
             descriptions_for_iris(
               Enum.map(ranked, & &1.iri),
               Keyword.merge(opts, model: model, output_dimensionality: dimensions)
             ) do
        results =
          ranked
          |> Enum.flat_map(fn ranked ->
            case Map.get(metadata, ranked.iri) do
              nil -> []
              unit -> [Map.merge(unit, %{score: ranked.score, run_iri: ranked.run_iri})]
            end
          end)
          |> Enum.take(limit)

        {:ok, results}
      end
    end
  end

  defp descriptions_sparql(iris) do
    values =
      iris
      |> Enum.uniq()
      |> Enum.map(&"<#{&1}>")
      |> Enum.join(" ")

    """
    SELECT ?iri ?doc ?p ?o WHERE {
      VALUES ?iri { #{values} }
      GRAPH ?doc {
        ?iri ?p ?o .
      }
    }
    """
  end

  defp document_titles_sparql do
    """
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX sheaf: <https://less.rest/sheaf/>

    SELECT ?doc ?title WHERE {
      GRAPH ?doc {
        ?doc a ?kind ;
          rdfs:label ?title .
        FILTER(?kind IN (sheaf:Document, sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
      }
    }
    """
  end

  defp graph_from_description_rows(rows) do
    Enum.reduce(rows, Graph.new(), fn row, graph ->
      iri = Map.fetch!(row, "iri")
      predicate = Map.fetch!(row, "p")
      object = Map.fetch!(row, "o")

      Graph.add(graph, {iri, predicate, object})
    end)
  end

  defp docs_by_iri(rows) do
    Map.new(rows, fn row ->
      {row |> Map.fetch!("iri") |> term_value(), row |> Map.fetch!("doc") |> term_value()}
    end)
  end

  defp unit_from_graph(%Graph{} = graph, iri, docs_by_iri, titles) do
    subject = RDF.iri(iri)
    description = RDF.Data.description(graph, subject)
    doc_iri = Map.get(docs_by_iri, iri)

    cond do
      text = first_value(description, Sheaf.NS.DOC.sourceHtml()) ->
        unit_from_description(description, "sourceHtml", text, doc_iri, titles)

      text = first_value(description, Sheaf.NS.DOC.text()) ->
        unit_from_description(description, "row", text, doc_iri, titles)

      paragraph = Description.first(description, Sheaf.NS.DOC.paragraph()) ->
        paragraph_description = RDF.Data.description(graph, paragraph)

        case first_value(paragraph_description, Sheaf.NS.DOC.text()) do
          nil -> nil
          text -> unit_from_description(description, "paragraph", text, doc_iri, titles)
        end

      true ->
        nil
    end
  end

  defp unit_from_description(%Description{} = description, kind, text, doc_iri, titles) do
    model = Sheaf.Embedding.model()

    %{
      iri: description.subject |> RDF.Term.value() |> to_string(),
      kind: kind,
      text: text,
      text_hash: text_hash(text, model, @default_dimensions),
      text_chars: String.length(text),
      doc_iri: doc_iri,
      doc_title: Map.get(titles, doc_iri),
      source_page: description |> Description.first(Sheaf.NS.DOC.sourcePage()) |> integer_value(),
      spreadsheet_row:
        description |> Description.first(Sheaf.NS.DOC.spreadsheetRow()) |> integer_value(),
      spreadsheet_source: first_value(description, Sheaf.NS.DOC.spreadsheetSource()),
      code_category_title: first_value(description, Sheaf.NS.DOC.codeCategoryTitle())
    }
  end

  defp first_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> term_value()
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp integer_value(nil), do: nil

  defp integer_value(term) do
    case RDF.Term.value(term) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> integer_parse_value()
      _ -> nil
    end
  end

  defp integer_parse_value({value, _rest}), do: value
  defp integer_parse_value(:error), do: nil
end
