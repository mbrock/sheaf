defmodule Sheaf.Embedding.Index do
  @moduledoc """
  Builds and queries Sheaf's derived SQLite embedding index.
  """

  require Logger

  alias RDF.{Description, Graph}
  alias Sheaf.Embedding.Store

  @default_dimensions 768
  @default_max_concurrency 8
  @default_batch_size 32
  @default_source "search-v1"
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
          optional(:source_block_type) => String.t() | nil,
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
    source = source(opts)
    run_iri = opts |> Keyword.get_lazy(:run_iri, fn -> Sheaf.mint() |> to_string() end)

    with {:ok, conn} <- Store.open(opts) do
      try do
        if import_run_iri = Keyword.get(opts, :import_run) do
          import_batch_run(conn, import_run_iri, opts)
        else
          with {:ok, units} <- text_units(Keyword.merge(opts, model: model, source: source)) do
            sync_run(conn, run_iri, units, model, dimensions, source, opts)
          end
        end
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
        source = source(opts)

        units =
          result.results
          |> Enum.map(&unit_from_row(&1, model, dimensions, source))
          |> Enum.reject(&(&1.text == ""))

        {:ok, units}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def text_hash(text, model, dimensions, source \\ @default_source) do
    :crypto.hash(:sha256, [
      source,
      <<0>>,
      model,
      <<0>>,
      Integer.to_string(dimensions),
      <<0>>,
      text
    ])
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
      source = source(opts)
      limit = Keyword.get(opts, :limit, 20)

      with {:ok, query_embedding} <-
             Sheaf.Embedding.embed_query(
               query,
               Keyword.merge(opts, output_dimensionality: dimensions)
             ),
           {:ok, conn} <- Store.open(opts) do
        try do
          search_loaded(
            conn,
            query_embedding.values,
            model,
            dimensions,
            source,
            limit,
            Keyword.put(opts, :query, query)
          )
        after
          Store.close(conn)
        end
      end
    end
  end

  defp sync_run(conn, run_iri, units, model, dimensions, source, opts) do
    reusable = Store.reusable_hashes(conn, model, dimensions, source)

    {missing, skipped} =
      Enum.split_with(units, fn unit -> !MapSet.member?(reusable, {unit.iri, unit.text_hash}) end)

    metadata = %{
      kinds: Enum.frequencies_by(units, & &1.kind),
      limit: Keyword.get(opts, :limit),
      requested_kinds: Keyword.get(opts, :kinds),
      source: source,
      task: "search",
      input_role: "document",
      api_mode: Keyword.get(opts, :api_mode, "batchEmbedContents")
    }

    with :ok <-
           Store.create_run(conn, %{
             iri: run_iri,
             model: model,
             dimensions: dimensions,
             source: source,
             target_count: length(units),
             skipped_count: length(skipped),
             metadata: metadata
           }) do
      Logger.info(
        "Embedding sync #{run_iri}: #{length(units)} current text units, #{length(skipped)} reusable, #{length(missing)} to embed"
      )

      if batch_api_mode?(opts) and Keyword.get(opts, :submit_only, false) and missing != [] do
        submit_batch_run(
          conn,
          run_iri,
          missing,
          skipped,
          units,
          model,
          dimensions,
          source,
          metadata,
          opts
        )
      else
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
             {:ok, vector_count} <- Store.sync_vector_index(conn, model, dimensions, source) do
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
  end

  defp submit_batch_run(
         conn,
         run_iri,
         missing,
         skipped,
         units,
         model,
         dimensions,
         source,
         metadata,
         opts
       ) do
    documents = documents_for_batch(missing)

    with {:ok, batch} <-
           Sheaf.Embedding.create_async_embed_batch(
             documents,
             Keyword.merge(opts,
               output_dimensionality: dimensions,
               task: :search,
               input_role: :document,
               batch_input: Keyword.get(opts, :batch_input, :file)
             )
           ) do
      batch_metadata =
        metadata
        |> Map.put(:api_mode, "batch_api")
        |> Map.put(:batch_name, batch.name)
        |> Map.put(:batch_state, batch.state)
        |> Map.put(:batch_stats, batch.stats)
        |> Map.put(:batch_units, Enum.map(missing, &batch_unit_metadata/1))

      :ok =
        Store.update_run(conn, run_iri, %{
          status: "running",
          embedded_count: 0,
          skipped_count: length(skipped),
          error_count: 0,
          metadata: batch_metadata
        })

      Logger.info("Embedding sync #{run_iri}: submitted Gemini batch #{batch.name}")

      {:ok,
       %{
         run_iri: run_iri,
         model: model,
         dimensions: dimensions,
         source: source,
         target_count: length(units),
         embedded_count: 0,
         skipped_count: length(skipped),
         error_count: 0,
         status: "submitted",
         batch_name: batch.name
       }}
    end
  end

  defp import_batch_run(conn, run_iri, opts) do
    with {:ok, run} <- Store.get_run(conn, run_iri),
         {:ok, run} <- require_run(run, run_iri),
         {:ok, batch_name} <- batch_name_from_run(run),
         {:ok, units} <- batch_units_from_run(run),
         {:ok, embeddings} <-
           Sheaf.Embedding.collect_async_embed_batch(
             batch_name,
             Keyword.merge(opts,
               model: run.model,
               output_dimensionality: run.dimensions
             )
           ) do
      embedded = min(length(units), length(embeddings))

      units
      |> Enum.zip(embeddings)
      |> Enum.each(fn {unit, embedding} ->
        :ok =
          Store.insert_embedding(conn, %{
            iri: unit.iri,
            run_iri: run_iri,
            text_hash: unit.text_hash,
            text_chars: unit.text_chars,
            values: embedding.values
          })
      end)

      errors = max(length(units) - embedded, 0)
      status = if errors == 0, do: "completed", else: "partial"

      metadata =
        run.metadata
        |> Map.put(
          "imported_at",
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        )
        |> Map.put("imported_count", embedded)

      with :ok <-
             Store.finish_run(conn, run_iri, %{
               status: status,
               embedded_count: embedded,
               skipped_count: run.skipped_count,
               error_count: errors,
               metadata: metadata
             }),
           {:ok, vector_count} <-
             Store.sync_vector_index(conn, run.model, run.dimensions, run.source) do
        Logger.info(
          "Embedding sync #{run_iri}: imported #{embedded}/#{length(units)} from #{batch_name} and refreshed sqlite-vec index with #{vector_count} vectors"
        )

        {:ok,
         %{
           run_iri: run_iri,
           model: run.model,
           dimensions: run.dimensions,
           target_count: run.target_count,
           embedded_count: embedded,
           skipped_count: run.skipped_count,
           error_count: errors,
           status: status
         }}
      end
    end
  end

  defp embed_missing(_conn, _run_iri, [], _dimensions, _opts) do
    %{embedded: 0, errors: 0, error_details: []}
  end

  defp embed_missing(conn, run_iri, units, dimensions, opts) do
    if batch_api_mode?(opts) do
      embed_missing_with_batch_api(conn, run_iri, units, dimensions, opts)
    else
      embed_missing_with_sync_batches(conn, run_iri, units, dimensions, opts)
    end
  end

  defp embed_missing_with_sync_batches(conn, run_iri, units, dimensions, opts) do
    total = length(units)
    concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    Logger.info(
      "Embedding sync #{run_iri}: starting #{total} embeddings with batch size #{batch_size} and concurrency #{concurrency}"
    )

    units
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(&embed_units(&1, dimensions, opts),
      max_concurrency: concurrency,
      ordered: false,
      timeout: Keyword.get(opts, :timeout, :infinity)
    )
    |> Enum.reduce(%{embedded: 0, errors: 0, error_details: []}, fn result, stats ->
      case result do
        {:ok, {:ok, pairs}} ->
          Enum.each(pairs, fn {unit, embedding} ->
            :ok =
              Store.insert_embedding(conn, %{
                iri: unit.iri,
                run_iri: run_iri,
                text_hash: unit.text_hash,
                text_chars: unit.text_chars,
                values: embedding.values
              })
          end)

          embedded = stats.embedded + length(pairs)

          if rem(embedded, 100) == 0 or embedded == total,
            do: Logger.info("Embedding sync #{run_iri}: stored #{embedded}/#{total}")

          %{stats | embedded: embedded}

        {:ok, {:error, units, reason}} ->
          Logger.warning(
            "Embedding sync #{run_iri}: failed batch starting #{List.first(units).iri}: #{inspect(reason)}"
          )

          %{
            stats
            | errors: stats.errors + length(units),
              error_details:
                Enum.map(units, &%{iri: &1.iri, reason: inspect(reason)}) ++ stats.error_details
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

  defp embed_missing_with_batch_api(conn, run_iri, units, dimensions, opts) do
    total = length(units)

    Logger.info(
      "Embedding sync #{run_iri}: submitting #{total} embeddings with Gemini async Batch API"
    )

    documents =
      Enum.with_index(units, fn unit, index ->
        %{
          key: Integer.to_string(index),
          text: unit.text,
          title: unit.doc_title
        }
      end)

    case Sheaf.Embedding.async_batch_embed_documents(
           documents,
           Keyword.merge(opts,
             output_dimensionality: dimensions,
             task: :search,
             input_role: :document,
             batch_input: Keyword.get(opts, :batch_input, :file)
           )
         ) do
      {:ok, embeddings} ->
        units
        |> Enum.zip(embeddings)
        |> Enum.each(fn {unit, embedding} ->
          :ok =
            Store.insert_embedding(conn, %{
              iri: unit.iri,
              run_iri: run_iri,
              text_hash: unit.text_hash,
              text_chars: unit.text_chars,
              values: embedding.values
            })
        end)

        Logger.info("Embedding sync #{run_iri}: stored #{length(embeddings)}/#{total}")

        %{
          embedded: length(embeddings),
          errors: max(total - length(embeddings), 0),
          error_details: []
        }

      {:error, reason} ->
        Logger.warning(
          "Embedding sync #{run_iri}: Batch API embedding failed: #{inspect(reason)}"
        )

        %{
          embedded: 0,
          errors: total,
          error_details: Enum.map(units, &%{iri: &1.iri, reason: inspect(reason)})
        }
    end
  end

  defp documents_for_batch(units) do
    Enum.with_index(units, fn unit, index ->
      %{
        key: Integer.to_string(index),
        text: unit.text,
        title: unit.doc_title
      }
    end)
  end

  defp batch_unit_metadata(unit) do
    %{
      iri: unit.iri,
      text_hash: unit.text_hash,
      text_chars: unit.text_chars
    }
  end

  defp require_run(nil, run_iri), do: {:error, {:unknown_embedding_run, run_iri}}
  defp require_run(run, _run_iri), do: {:ok, run}

  defp batch_name_from_run(%{metadata: %{"batch_name" => batch_name}}) when is_binary(batch_name),
    do: {:ok, batch_name}

  defp batch_name_from_run(run), do: {:error, {:missing_batch_name, run.iri}}

  defp batch_units_from_run(%{metadata: %{"batch_units" => units}}) when is_list(units) do
    {:ok,
     Enum.map(units, fn unit ->
       %{
         iri: Map.fetch!(unit, "iri"),
         text_hash: Map.fetch!(unit, "text_hash"),
         text_chars: Map.fetch!(unit, "text_chars")
       }
     end)}
  end

  defp batch_units_from_run(run), do: {:error, {:missing_batch_units, run.iri}}

  defp embed_units(units, dimensions, opts) do
    documents = documents_for_batch(units)

    case Sheaf.Embedding.embed_documents(
           documents,
           Keyword.merge(opts,
             output_dimensionality: dimensions,
             task: :search,
             input_role: :document
           )
         ) do
      {:ok, embeddings} -> {:ok, Enum.zip(units, embeddings)}
      {:error, reason} -> {:error, units, reason}
    end
  end

  defp batch_api_mode?(opts) do
    Keyword.get(opts, :api_mode) in [:batch, "batch", :batch_api, "batch_api", "async_batch"]
  end

  defp text_units_sparql(opts) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()
    limit = Keyword.get(opts, :limit)

    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX prov: <http://www.w3.org/ns/prov#>

    SELECT ?iri ?kind ?text ?doc ?docTitle ?sourcePage ?sourceBlockType ?spreadsheetRow ?spreadsheetSource ?codeCategoryTitle WHERE {
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
       OPTIONAL { ?iri sheaf:sourceBlockType ?sourceBlockType }
       FILTER(!BOUND(?sourceBlockType) || STR(?sourceBlockType) = "Text")
       FILTER(!CONTAINS(STR(?text), ";base64,"))
       FILTER(!CONTAINS(STR(?text), "data:image/"))
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

  defp unit_from_row(row, model, dimensions, source) do
    text = row |> Map.fetch!("text") |> term_value()
    doc_title = row |> Map.get("docTitle") |> term_value()
    embedding_text = embedding_document_text(text, doc_title, model)

    %{
      iri: row |> Map.fetch!("iri") |> term_value(),
      kind: row |> Map.fetch!("kind") |> term_value(),
      text: text,
      text_hash: text_hash(embedding_text, model, dimensions, source),
      text_chars: String.length(text),
      doc_iri: row |> Map.get("doc") |> term_value(),
      doc_title: doc_title,
      source_page: row |> Map.get("sourcePage") |> integer_value(),
      source_block_type: row |> Map.get("sourceBlockType") |> term_value(),
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

  defp search_loaded(conn, query_values, model, dimensions, source, limit, opts) do
    exact_limit = Keyword.get(opts, :exact_limit, max(limit * 4, 60))

    with {:ok, exact_results} <-
           exact_matches(
             Keyword.fetch!(opts, :query),
             Keyword.merge(opts,
               model: model,
               output_dimensionality: dimensions,
               source: source,
               limit: exact_limit
             )
           ),
         {:ok, vector_results} <-
           vector_results_until(conn, query_values, model, dimensions, source, limit, opts) do
      {:ok,
       (exact_results ++ vector_results)
       |> merge_ranked_results()
       |> Enum.take(limit)}
    end
  end

  defp vector_results_until(conn, query_values, model, dimensions, source, limit, opts) do
    initial_candidate_limit = Keyword.get(opts, :candidate_limit, max(limit * 4, 80))

    max_candidate_limit =
      Keyword.get(opts, :max_candidate_limit, max(initial_candidate_limit, 500))

    do_vector_results_until(
      conn,
      query_values,
      model,
      dimensions,
      source,
      limit,
      initial_candidate_limit,
      max_candidate_limit,
      opts
    )
  end

  defp do_vector_results_until(
         conn,
         query_values,
         model,
         dimensions,
         source,
         limit,
         candidate_limit,
         max_candidate_limit,
         opts
       ) do
    with {:ok, ranked} <-
           Store.search_vectors(conn, query_values, model, dimensions, candidate_limit, source),
         {:ok, metadata} <-
           descriptions_for_iris(
             Enum.map(ranked, & &1.iri),
             Keyword.merge(opts, model: model, output_dimensionality: dimensions)
           ) do
      results =
        ranked
        |> Enum.flat_map(fn ranked ->
          case Map.get(metadata, ranked.iri) do
            nil ->
              []

            unit ->
              unit
              |> Map.merge(%{
                score: ranked.score,
                semantic_score: ranked.score,
                lexical_score: 0.0,
                match: :semantic,
                run_iri: ranked.run_iri
              })
              |> searchable_result(opts)
          end
        end)

      if length(results) >= limit or candidate_limit >= max_candidate_limit do
        {:ok, results}
      else
        do_vector_results_until(
          conn,
          query_values,
          model,
          dimensions,
          source,
          limit,
          min(candidate_limit * 2, max_candidate_limit),
          max_candidate_limit,
          opts
        )
      end
    end
  end

  defp exact_matches(query, opts) do
    select = Keyword.get(opts, :select, &Sheaf.select/1)
    model = Keyword.get(opts, :model, Sheaf.Embedding.model())
    dimensions = Keyword.get(opts, :output_dimensionality, @default_dimensions)
    source = source(opts)

    case select.(exact_matches_sparql(query, opts)) do
      {:ok, result} ->
        results =
          result.results
          |> Enum.map(fn row ->
            row
            |> unit_from_row(model, dimensions, source)
            |> Map.merge(%{
              score: exact_result_score(row),
              semantic_score: nil,
              lexical_score: exact_result_score(row),
              match: :exact,
              run_iri: nil
            })
          end)
          |> Enum.flat_map(&searchable_result(&1, opts))

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_matches_sparql(query, opts) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()
    limit = Keyword.get(opts, :limit, 60)
    escaped = escape_sparql_string(query)
    terms = search_terms(query)
    match_filter = search_match_filter(escaped, terms)
    score_bind = search_score_bind(escaped, terms)
    scope_filter = document_scope_filter(Keyword.get(opts, :document_id))

    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX prov: <http://www.w3.org/ns/prov#>

    SELECT ?iri ?kind ?text ?doc ?docTitle ?sourcePage ?sourceBlockType ?spreadsheetRow ?spreadsheetSource ?codeCategoryTitle ?score WHERE {
      GRAPH ?doc {
        OPTIONAL { ?doc <http://www.w3.org/2000/01/rdf-schema#label> ?docTitle }
        #{text_unit_unions(kinds)}
        #{scope_filter}
        BIND(LCASE(STR(?text)) AS ?haystack)
        #{match_filter}
        #{score_bind}
      }
    }
    ORDER BY DESC(?score)
    LIMIT #{limit}
    """
  end

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
  end

  defp search_match_filter(escaped_query, []),
    do: ~s/FILTER(CONTAINS(?haystack, LCASE("#{escaped_query}")))/

  defp search_match_filter(escaped_query, terms) do
    keyword_match =
      terms
      |> Enum.map(&~s/CONTAINS(?haystack, "#{escape_sparql_string(&1)}")/)
      |> Enum.join(" || ")

    ~s/FILTER(CONTAINS(?haystack, LCASE("#{escaped_query}")) || #{keyword_match})/
  end

  defp search_score_bind(escaped_query, []),
    do: ~s/BIND(IF(CONTAINS(?haystack, LCASE("#{escaped_query}")), 100, 0) AS ?score)/

  defp search_score_bind(escaped_query, terms) do
    keyword_score =
      terms
      |> Enum.map(&~s/IF(CONTAINS(?haystack, "#{escape_sparql_string(&1)}"), 1, 0)/)
      |> Enum.join(" + ")

    """
    BIND(IF(CONTAINS(?haystack, LCASE("#{escaped_query}")), 100, 0) AS ?exactScore)
    BIND((?exactScore + #{keyword_score}) AS ?score)
    """
    |> String.trim()
  end

  defp escape_sparql_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
  end

  defp exact_result_score(row) do
    case row |> Map.get("score") |> term_value() do
      nil -> 0.75
      score -> min(0.98, 0.72 + parse_score(score) / 120.0)
    end
  end

  defp parse_score(score) when is_integer(score), do: score * 1.0
  defp parse_score(score) when is_float(score), do: score

  defp parse_score(score) when is_binary(score) do
    case Float.parse(score) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  defp parse_score(_score), do: 0.0

  defp document_scope_filter(nil), do: ""
  defp document_scope_filter(""), do: ""
  defp document_scope_filter(document_id), do: "FILTER(?doc = <#{Sheaf.Id.iri(document_id)}>)"

  defp searchable_result(result, opts) do
    if kind_allowed?(result, opts) and document_allowed?(result, opts) and
         searchable_content?(result) do
      [result]
    else
      []
    end
  end

  defp kind_allowed?(result, opts) do
    result.kind in (opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap())
  end

  defp document_allowed?(result, opts) do
    case Keyword.get(opts, :document_id) do
      nil -> true
      "" -> true
      document_id -> result.doc_iri == document_id |> Sheaf.Id.iri() |> to_string()
    end
  end

  defp searchable_content?(%{kind: "sourceHtml"} = result),
    do: searchable_extracted_block?(result)

  defp searchable_content?(_result), do: true

  defp searchable_extracted_block?(result) do
    source_type = Map.get(result, :source_block_type)
    text = Map.get(result, :text, "")

    source_type in [nil, "", "Text"] and not base64_html?(text)
  end

  defp base64_html?(text) when is_binary(text) do
    String.contains?(text, ";base64,") or String.contains?(text, "data:image/")
  end

  defp base64_html?(_text), do: false

  defp merge_ranked_results(results) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      Map.update(acc, result.iri, result, &merge_result(&1, result))
    end)
    |> Map.values()
    |> Enum.sort_by(&{-&1.score, match_sort(&1), &1.iri})
  end

  defp merge_result(left, right) do
    lexical_score = max(score_value(left.lexical_score), score_value(right.lexical_score))
    semantic_score = max(score_value(left.semantic_score), score_value(right.semantic_score))
    match = merged_match(left.match, right.match)

    Map.merge(left, %{
      score: combined_score(semantic_score, lexical_score, match),
      semantic_score: semantic_score_or_nil(semantic_score),
      lexical_score: lexical_score,
      match: match,
      run_iri: left.run_iri || right.run_iri
    })
  end

  defp combined_score(semantic_score, lexical_score, :both),
    do: min(1.0, max(semantic_score, lexical_score) + 0.04)

  defp combined_score(semantic_score, lexical_score, _match),
    do: max(semantic_score, lexical_score)

  defp merged_match(:both, _match), do: :both
  defp merged_match(_match, :both), do: :both
  defp merged_match(:exact, :semantic), do: :both
  defp merged_match(:semantic, :exact), do: :both
  defp merged_match(match, _other), do: match

  defp score_value(nil), do: 0.0
  defp score_value(score) when is_float(score), do: score
  defp score_value(score) when is_integer(score), do: score * 1.0

  defp semantic_score_or_nil(score) when score == 0.0, do: nil
  defp semantic_score_or_nil(score), do: score

  defp match_sort(%{match: :both}), do: 0
  defp match_sort(%{match: :exact}), do: 1
  defp match_sort(_result), do: 2

  defp descriptions_sparql(iris) do
    values =
      iris
      |> Enum.uniq()
      |> Enum.map(&"<#{&1}>")
      |> Enum.join(" ")

    """
    PREFIX sheaf: <https://less.rest/sheaf/>

    SELECT ?iri ?doc ?s ?p ?o WHERE {
      VALUES ?iri { #{values} }
      GRAPH ?doc {
        {
          ?iri ?p ?o .
          BIND(?iri AS ?s)
        } UNION {
          ?iri sheaf:paragraph ?para .
          ?para ?p ?o .
          BIND(?para AS ?s)
        }
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
      iri = Map.get(row, "s") || Map.fetch!(row, "iri")
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
    doc_title = Map.get(titles, doc_iri)

    %{
      iri: description.subject |> RDF.Term.value() |> to_string(),
      kind: kind,
      text: text,
      text_hash:
        text_hash(embedding_document_text(text, doc_title, model), model, @default_dimensions),
      text_chars: String.length(text),
      doc_iri: doc_iri,
      doc_title: doc_title,
      source_page: description |> Description.first(Sheaf.NS.DOC.sourcePage()) |> integer_value(),
      source_block_type: first_value(description, Sheaf.NS.DOC.sourceBlockType()),
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

  defp source(opts), do: Keyword.get(opts, :source, Keyword.get(opts, :profile, @default_source))

  defp embedding_document_text(text, title, model) do
    Sheaf.Embedding.prepared_text(text,
      model: model,
      task: :search,
      input_role: :document,
      title: title
    )
  end
end
