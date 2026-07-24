defmodule Sheaf.Embedding.Index do
  @moduledoc """
  Builds and queries Sheaf's derived SQLite embedding index.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.{Description, Graph}
  alias Sheaf.Document
  alias Sheaf.Embedding.Store
  alias Sheaf.NS.{DCTERMS, DOC, FABIO, FOAF}
  alias RDF.NS.RDFS

  @default_dimensions 768
  @default_max_concurrency 8
  @default_batch_size 32
  @default_source "openai-text-embedding-3-large-v1"
  @valid_kinds ~w(paragraph sourceHtml row note gitCommit sourceFile)
  @default_source_file_segment_bytes 8_000
  @default_source_file_segment_overlap_bytes 512
  @semantic_min_words 20
  @context_variant_fragment "#sheaf-context"
  @source_file_segment_fragment "#sheaf-embedding-segment-"

  @type text_unit :: %{
          required(:iri) => String.t(),
          required(:kind) => String.t(),
          required(:text) => String.t(),
          required(:text_hash) => String.t(),
          required(:text_chars) => non_neg_integer(),
          optional(:embedding_input_bytes) => non_neg_integer(),
          optional(:citation_iri) => String.t(),
          optional(:embedding_variant) => atom(),
          optional(:doc_iri) => String.t() | nil,
          optional(:doc_title) => String.t() | nil,
          optional(:doc_authors) => [String.t()],
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

    dimensions =
      Keyword.get(opts, :output_dimensionality, @default_dimensions)

    source = source(opts)

    run_iri =
      opts
      |> Keyword.get_lazy(:run_iri, fn -> Sheaf.mint() |> to_string() end)

    with {:ok, conn} <- Store.open(opts) do
      try do
        if import_run_iri = Keyword.get(opts, :import_run) do
          import_batch_run(conn, import_run_iri, opts)
        else
          with {:ok, units} <-
                 text_units(Keyword.merge(opts, model: model, source: source)) do
            sync_run(conn, run_iri, units, model, dimensions, source, opts)
          end
        end
      after
        Store.close(conn)
      end
    end
  end

  @doc """
  Embeds missing or stale text units that were already read from RDF.

  The units must have been built for the same model, dimensions, and source as
  the options passed here.
  """
  @spec sync_units([text_unit()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_units(units, opts \\ []) when is_list(units) do
    model = Sheaf.Embedding.model(opts)

    dimensions =
      Keyword.get(opts, :output_dimensionality, @default_dimensions)

    source = source(opts)

    run_iri =
      opts
      |> Keyword.get_lazy(:run_iri, fn -> Sheaf.mint() |> to_string() end)

    with {:ok, conn} <- Store.open(opts) do
      try do
        sync_run(conn, run_iri, units, model, dimensions, source, opts)
      after
        Store.close(conn)
      end
    end
  end

  @doc """
  Reports what an embedding sync would embed without calling an embedding API.
  """
  @spec plan(keyword()) :: {:ok, map()} | {:error, term()}
  def plan(opts \\ []) do
    model = Sheaf.Embedding.model(opts)

    dimensions =
      Keyword.get(opts, :output_dimensionality, @default_dimensions)

    source = source(opts)

    with {:ok, units} <-
           text_units(Keyword.merge(opts, model: model, source: source)),
         {:ok, conn} <- Store.open(opts) do
      try do
        reusable = Store.reusable_hashes(conn, model, dimensions, source)

        {missing, skipped} =
          Enum.split_with(units, fn unit ->
            !MapSet.member?(reusable, {unit.iri, unit.text_hash})
          end)

        {:ok,
         %{
           model: model,
           dimensions: dimensions,
           source: source,
           target_count: length(units),
           reusable_count: length(skipped),
           missing_count: length(missing),
           missing_kinds: Enum.frequencies_by(missing, & &1.kind),
           sample: Enum.take(missing, Keyword.get(opts, :sample, 20))
         }}
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
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()

    with {:ok, rows} <- Sheaf.TextUnits.fetch_rows(kinds: kinds) do
      model = Keyword.get(opts, :model, Sheaf.Embedding.model())
      source = source(opts)

      {:ok,
       units_from_rows(
         rows,
         Keyword.merge(opts, model: model, source: source)
       )}
    end
  end

  @doc """
  Builds embedding text units from already-fetched RDF text rows.
  """
  @spec units_from_rows([map()], keyword()) :: [text_unit()]
  def units_from_rows(rows, opts \\ []) when is_list(rows) do
    model = Keyword.get(opts, :model, Sheaf.Embedding.model())

    dimensions =
      Keyword.get(opts, :output_dimensionality, @default_dimensions)

    source = source(opts)

    rows
    |> Enum.flat_map(&units_from_row(&1, model, dimensions, source, opts))
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(& &1.iri)
    |> maybe_limit_units(opts)
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

    Tracer.with_span "Sheaf.Embedding.Index.search", %{
      kind: :internal,
      attributes: [
        {"sheaf.retrieval.query", query},
        {"sheaf.retrieval.limit", Keyword.get(opts, :limit, 20)},
        {"sheaf.retrieval.document_id", Keyword.get(opts, :document_id, "")},
        {"sheaf.retrieval.fusion", "reciprocal_rank"}
      ]
    } do
      if query == "" do
        {:ok, []}
      else
        model = Sheaf.Embedding.model(opts)

        dimensions =
          Keyword.get(opts, :output_dimensionality, @default_dimensions)

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
  end

  @doc """
  Searches only exact lexical matches from the SQLite sidecar and hydrates them
  with RDF metadata.
  """
  @spec exact_search(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def exact_search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      exact_matches(query, opts)
    end
  end

  defp sync_run(conn, run_iri, units, model, dimensions, source, opts) do
    reusable = Store.reusable_hashes(conn, model, dimensions, source)

    {missing, skipped} =
      Enum.split_with(units, fn unit ->
        !MapSet.member?(reusable, {unit.iri, unit.text_hash})
      end)

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

      if async_batch_api_mode?(opts) and
           Keyword.get(opts, :submit_only, false) and missing != [] do
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

        vector_current_hashes =
          Keyword.get_lazy(opts, :current_hashes, fn ->
            current_hashes(units)
          end)

        with :ok <- Store.finish_run(conn, run_iri, finish_attrs),
             {:ok, vector_count} <-
               sync_vectors_after_run(
                 conn,
                 model,
                 dimensions,
                 source,
                 vector_current_hashes,
                 opts
               ) do
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

      Logger.info(
        "Embedding sync #{run_iri}: submitted Gemini batch #{batch.name}"
      )

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
    else
      {:error, reason} = error ->
        :ok =
          Store.finish_run(conn, run_iri, %{
            status: "failed",
            embedded_count: 0,
            skipped_count: length(skipped),
            error_count: length(missing),
            metadata: Map.put(metadata, :error, inspect(reason))
          })

        error
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
           ),
         {:ok, import_pairs, current_skipped} <-
           current_import_pairs(Enum.zip(units, embeddings), opts) do
      embedded = length(import_pairs)

      Enum.each(import_pairs, fn {unit, embedding} ->
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
      errors = max(errors - current_skipped, 0)
      status = if errors == 0, do: "completed", else: "partial"

      metadata =
        run.metadata
        |> Map.put(
          "imported_at",
          DateTime.utc_now()
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
        )
        |> Map.put("imported_count", embedded)
        |> Map.put("import_skipped_current_count", current_skipped)

      with :ok <-
             Store.finish_run(conn, run_iri, %{
               status: status,
               embedded_count: embedded,
               skipped_count: run.skipped_count + current_skipped,
               error_count: errors,
               metadata: metadata
             }),
           {:ok, vector_count} <-
             Store.sync_vector_index(
               conn,
               run.model,
               run.dimensions,
               run.source,
               current_hashes: current_hashes(units)
             ) do
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
           skipped_count: run.skipped_count + current_skipped,
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
    if async_batch_api_mode?(opts) do
      embed_missing_with_batch_api(conn, run_iri, units, dimensions, opts)
    else
      embed_missing_with_sync_batches(conn, run_iri, units, dimensions, opts)
    end
  end

  defp embed_missing_with_sync_batches(conn, run_iri, units, dimensions, opts) do
    total = length(units)

    concurrency =
      Keyword.get(opts, :max_concurrency, @default_max_concurrency)

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
    |> Enum.reduce(%{embedded: 0, errors: 0, error_details: []}, fn result,
                                                                    stats ->
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
            do:
              Logger.info(
                "Embedding sync #{run_iri}: stored #{embedded}/#{total}"
              )

          %{stats | embedded: embedded}

        {:ok, {:error, units, reason}} ->
          Logger.warning(
            "Embedding sync #{run_iri}: failed batch starting #{List.first(units).iri}: #{inspect(reason)}"
          )

          %{
            stats
            | errors: stats.errors + length(units),
              error_details:
                Enum.map(units, &%{iri: &1.iri, reason: inspect(reason)}) ++
                  stats.error_details
          }

        {:exit, reason} ->
          Logger.warning(
            "Embedding sync #{run_iri}: task exited: #{inspect(reason)}"
          )

          %{
            stats
            | errors: stats.errors + 1,
              error_details: [
                %{reason: inspect(reason)} | stats.error_details
              ]
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

        Logger.info(
          "Embedding sync #{run_iri}: stored #{length(embeddings)}/#{total}"
        )

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
          error_details:
            Enum.map(units, &%{iri: &1.iri, reason: inspect(reason)})
        }
    end
  end

  defp documents_for_batch(units) do
    Enum.with_index(units, fn unit, index ->
      %{
        key: Integer.to_string(index),
        text: Map.get(unit, :embedding_text, unit.text),
        title: Map.get(unit, :embedding_title, unit.doc_title)
      }
    end)
  end

  defp batch_unit_metadata(unit) do
    %{
      iri: unit.iri,
      doc_iri: unit.doc_iri,
      text_hash: unit.text_hash,
      text_chars: unit.text_chars
    }
  end

  defp sync_vectors_after_run(
         conn,
         model,
         dimensions,
         source,
         current_hashes,
         opts
       ) do
    case Keyword.get(opts, :vector_iris) do
      iris when is_list(iris) ->
        Store.sync_vector_index_for_iris(
          conn,
          model,
          dimensions,
          source,
          iris,
          current_hashes: current_hashes
        )

      _all ->
        Store.sync_vector_index(conn, model, dimensions, source,
          current_hashes: current_hashes
        )
    end
  end

  defp require_run(nil, run_iri),
    do: {:error, {:unknown_embedding_run, run_iri}}

  defp require_run(run, _run_iri), do: {:ok, run}

  defp batch_name_from_run(%{metadata: %{"batch_name" => batch_name}})
       when is_binary(batch_name),
       do: {:ok, batch_name}

  defp batch_name_from_run(run), do: {:error, {:missing_batch_name, run.iri}}

  defp batch_units_from_run(%{metadata: %{"batch_units" => units}})
       when is_list(units) do
    {:ok,
     Enum.map(units, fn unit ->
       %{
         iri: Map.fetch!(unit, "iri"),
         doc_iri: Map.get(unit, "doc_iri"),
         text_hash: Map.fetch!(unit, "text_hash"),
         text_chars: Map.fetch!(unit, "text_chars")
       }
     end)}
  end

  defp batch_units_from_run(run),
    do: {:error, {:missing_batch_units, run.iri}}

  defp current_import_pairs([], _opts), do: {:ok, [], 0}

  defp current_import_pairs(pairs, opts) do
    iris =
      pairs
      |> Enum.map(fn {unit, _embedding} -> citation_iri(unit.iri) end)
      |> Enum.uniq()

    with {:ok, current_units} <- descriptions_for_iris(iris, opts) do
      {included, skipped} =
        Enum.split_with(pairs, fn {unit, _embedding} ->
          case Map.get(current_units, citation_iri(unit.iri)) do
            %{doc_excluded?: true} -> false
            nil -> false
            _unit -> true
          end
        end)

      {:ok, included, length(skipped)}
    end
  end

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
    Keyword.get(opts, :api_mode) in [
      :batch,
      "batch",
      :batch_api,
      "batch_api",
      "async_batch"
    ]
  end

  defp async_batch_api_mode?(opts) do
    batch_api_mode?(opts) and Sheaf.Embedding.provider(opts) == :gemini
  end

  defp maybe_limit_units(units, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(units, limit)
      _limit -> units
    end
  end

  defp current_hashes(units) do
    units
    |> Enum.map(&{&1.iri, &1.text_hash})
    |> MapSet.new()
  end

  defp units_from_row(row, model, dimensions, source, opts) do
    text = row |> Map.fetch!("text") |> term_value()
    search_text = Map.get(row, "searchText") || text
    doc_title = row |> Map.get("docTitle") |> term_value()
    prepared = embedding_document_text(search_text, doc_title, model)
    kind = row |> Map.fetch!("kind") |> term_value()

    unit = %{
      iri: row |> Map.fetch!("iri") |> term_value(),
      kind: kind,
      text: text,
      embedding_text: search_text,
      embedding_title: doc_title,
      embedding_variant: :precise,
      text_hash: text_hash(prepared, model, dimensions, source),
      text_chars: String.length(text),
      embedding_input_bytes: byte_size(prepared),
      doc_iri: row |> Map.get("doc") |> term_value(),
      doc_title: doc_title,
      source_page: row |> Map.get("sourcePage") |> integer_value(),
      source_block_type: row |> Map.get("sourceBlockType") |> term_value(),
      spreadsheet_row: row |> Map.get("spreadsheetRow") |> integer_value(),
      spreadsheet_source: row |> Map.get("spreadsheetSource") |> term_value(),
      code_category_title:
        row |> Map.get("codeCategoryTitle") |> term_value(),
      breadcrumbs: Map.get(row, "breadcrumbs", []),
      previous: Map.get(row, "previous"),
      following: Map.get(row, "following")
    }

    if kind == "sourceFile" do
      source_file_embedding_units(
        unit,
        model,
        dimensions,
        source,
        opts
      )
    else
      [unit | contextual_units(unit, row, model, dimensions, source)]
    end
  end

  defp contextual_units(%{kind: kind} = unit, row, model, dimensions, source)
       when kind in ["paragraph", "sourceHtml"] do
    context_text = contextual_embedding_text(unit, row)

    if context_text == unit.embedding_text do
      []
    else
      prepared = embedding_document_text(context_text, nil, model)

      [
        %{
          unit
          | iri: context_variant_iri(unit.iri),
            embedding_text: context_text,
            embedding_title: nil,
            embedding_variant: :context,
            text_hash: text_hash(prepared, model, dimensions, source),
            text_chars: String.length(context_text)
        }
        |> Map.put(:citation_iri, unit.iri)
      ]
    end
  end

  defp contextual_units(_unit, _row, _model, _dimensions, _source), do: []

  defp source_file_embedding_units(
         unit,
         model,
         dimensions,
         source,
         opts
       ) do
    segments = source_file_segments(unit.text, unit.doc_title, opts)

    case segments do
      [%{embedding_text: embedding_text, text: text}] ->
        prepared =
          embedding_document_text(embedding_text, unit.doc_title, model)

        [
          %{
            unit
            | text: text,
              embedding_text: embedding_text,
              text_hash: text_hash(prepared, model, dimensions, source),
              text_chars: String.length(text),
              embedding_input_bytes: byte_size(prepared)
          }
        ]

      segments ->
        Enum.map(segments, fn segment ->
          prepared =
            embedding_document_text(
              segment.embedding_text,
              unit.doc_title,
              model
            )

          %{
            unit
            | iri: source_file_segment_iri(unit.iri, segment.index),
              text: segment.text,
              embedding_text: segment.embedding_text,
              text_hash: text_hash(prepared, model, dimensions, source),
              text_chars: String.length(segment.text),
              embedding_input_bytes: byte_size(prepared),
              embedding_variant: :segment
          }
          |> Map.put(:citation_iri, unit.iri)
        end)
    end
  end

  @doc false
  def source_file_segments(text, title, opts \\ [])
      when is_binary(text) do
    context =
      case title do
        title when is_binary(title) and title != "" -> "Path: #{title}\n"
        _other -> ""
      end

    max_bytes =
      Keyword.get(
        opts,
        :source_file_segment_bytes,
        @default_source_file_segment_bytes
      )

    overlap_bytes =
      Keyword.get(
        opts,
        :source_file_segment_overlap_bytes,
        @default_source_file_segment_overlap_bytes
      )

    payload_bytes = max(max_bytes - byte_size(context), 1)

    text
    |> split_utf8_segments(
      payload_bytes,
      min(overlap_bytes, payload_bytes - 1)
    )
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      %{index: index, text: segment, embedding_text: context <> segment}
    end)
  end

  defp split_utf8_segments(text, max_bytes, _overlap_bytes)
       when byte_size(text) <= max_bytes,
       do: [text]

  defp split_utf8_segments(text, max_bytes, overlap_bytes) do
    {segment, rest} = take_utf8_segment(text, max_bytes)
    overlap = utf8_suffix(segment, overlap_bytes)
    [segment | split_utf8_segments(overlap <> rest, max_bytes, overlap_bytes)]
  end

  defp take_utf8_segment(text, max_bytes) do
    prefix =
      case valid_utf8_prefix(text, max_bytes) do
        "" ->
          <<codepoint::utf8, _rest::binary>> = text
          <<codepoint::utf8>>

        prefix ->
          prefix
      end

    split_at =
      prefix
      |> :binary.matches("\n")
      |> List.last()
      |> case do
        {position, length} when position >= div(byte_size(prefix), 2) ->
          position + length

        _other ->
          byte_size(prefix)
      end

    {
      binary_part(text, 0, split_at),
      binary_part(text, split_at, byte_size(text) - split_at)
    }
  end

  defp valid_utf8_prefix(text, max_bytes) do
    size = min(byte_size(text), max_bytes)
    do_valid_utf8_prefix(text, size)
  end

  defp do_valid_utf8_prefix(text, size) do
    prefix = binary_part(text, 0, size)

    if String.valid?(prefix),
      do: prefix,
      else: do_valid_utf8_prefix(text, size - 1)
  end

  defp utf8_suffix(_text, bytes) when bytes <= 0, do: ""

  defp utf8_suffix(text, bytes) do
    start = max(byte_size(text) - bytes, 0)
    do_utf8_suffix(text, start)
  end

  defp do_utf8_suffix(text, start) do
    suffix = binary_part(text, start, byte_size(text) - start)

    if String.valid?(suffix),
      do: suffix,
      else: do_utf8_suffix(text, start + 1)
  end

  defp contextual_embedding_text(unit, row) do
    [
      labeled_context("Document", unit.doc_title),
      labeled_context(
        "Section",
        Enum.join(Map.get(row, "breadcrumbs", []), " > ")
      ),
      labeled_context("Previous", neighbor_text(Map.get(row, "previous"))),
      labeled_context("Passage", unit.embedding_text),
      labeled_context("Next", neighbor_text(Map.get(row, "following")))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp labeled_context(_label, value) when value in [nil, ""], do: nil
  defp labeled_context(label, value), do: "#{label}: #{value}"

  defp neighbor_text(%{"text" => text}) when is_binary(text), do: text
  defp neighbor_text(_neighbor), do: nil

  defp context_variant_iri(iri), do: iri <> @context_variant_fragment

  defp citation_iri(iri) do
    cond do
      String.ends_with?(iri, @context_variant_fragment) ->
        String.replace_suffix(iri, @context_variant_fragment, "")

      source_file_segment_index(iri) != nil ->
        Regex.replace(
          ~r/#{Regex.escape(@source_file_segment_fragment)}\d+$/,
          iri,
          "#content"
        )

      true ->
        iri
    end
  end

  defp embedding_variant(iri) do
    cond do
      String.ends_with?(iri, @context_variant_fragment) -> :context
      source_file_segment_index(iri) != nil -> :segment
      true -> :precise
    end
  end

  defp embedding_variant_allowed?(iri, opts) do
    allowed =
      opts
      |> Keyword.get(:embedding_variants, [:precise, :context, :segment])
      |> List.wrap()

    embedding_variant(iri) in allowed
  end

  defp source_file_segment_iri(iri, index) do
    base = String.replace_suffix(iri, "#content", "")

    base <>
      @source_file_segment_fragment <>
      (index |> Integer.to_string() |> String.pad_leading(4, "0"))
  end

  defp source_file_segment_index(iri) do
    case Regex.run(
           ~r/#{Regex.escape(@source_file_segment_fragment)}(\d+)$/,
           iri
         ) do
      [_whole, index] -> String.to_integer(index)
      _other -> nil
    end
  end

  @doc false
  def metadata_for_iris(iris, opts \\ []),
    do: descriptions_for_iris(iris, opts)

  @doc false
  def descriptions_for_iris(iris, opts \\ [])

  def descriptions_for_iris([], _opts), do: {:ok, %{}}

  def descriptions_for_iris(iris, opts) when is_list(iris) do
    with {:ok, rows} <- description_rows_for_iris(iris) do
      graph = graph_for_rows(rows, iris)
      docs_by_iri = docs_by_iri(rows, iris)

      doc_iris =
        docs_by_iri |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()

      with {:ok, documents} <- document_metadata_for_doc_iris(doc_iris, opts) do
        {:ok,
         iris
         |> Enum.uniq()
         |> Enum.map(&unit_from_graph(graph, &1, docs_by_iri, documents))
         |> Enum.reject(&is_nil/1)
         |> Map.new(&{&1.iri, &1})}
      end
    end
  end

  defp sidecar_descriptions_for_iris([], _opts), do: {:ok, %{}}

  defp sidecar_descriptions_for_iris(iris, opts) when is_list(iris) do
    with {:ok, loaded_units} <- Sheaf.Search.Index.units_by_iris(iris, opts),
         units <- filter_sidecar_units(loaded_units, opts),
         {:ok, documents} <-
           units
           |> Map.values()
           |> Enum.reject(&(&1.kind == "note"))
           |> Enum.map(& &1.doc_iri)
           |> document_metadata_for_doc_iris(opts) do
      retrieval_contexts = retrieval_context_metadata(units)

      {:ok,
       iris
       |> Enum.uniq()
       |> Enum.map(
         &unit_from_sidecar(units, &1, documents, retrieval_contexts)
       )
       |> Enum.reject(&is_nil/1)
       |> Map.new(&{&1.iri, &1})}
    end
  end

  defp filter_sidecar_units(units, opts) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()

    document_iri =
      case Keyword.get(opts, :document_id) do
        document_id when document_id in [nil, ""] -> nil
        document_id -> document_id |> Sheaf.Id.iri() |> to_string()
      end

    units
    |> Enum.filter(fn {_iri, unit} ->
      unit.kind in kinds and
        (is_nil(document_iri) or unit.doc_iri == document_iri)
    end)
    |> Map.new()
  end

  @doc false
  def document_metadata(opts) do
    case Keyword.get(opts, :documents) do
      documents when is_map(documents) -> {:ok, documents}
      _other -> load_document_metadata()
    end
  end

  @doc false
  def document_metadata, do: load_document_metadata()

  defp document_metadata_for_doc_iris(doc_iris, opts) do
    doc_iris = doc_iris |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case Keyword.get(opts, :documents) do
      documents when is_map(documents) ->
        documents
        |> Map.take(doc_iris)
        |> then(&{:ok, &1})

      _other ->
        load_document_metadata_for_doc_iris(doc_iris)
    end
  end

  defp load_document_metadata_for_doc_iris([]), do: {:ok, %{}}

  defp load_document_metadata_for_doc_iris(doc_iris) do
    with {:ok, metadata} <- Sheaf.fetch_graph(Sheaf.Repo.metadata_graph()),
         {:ok, workspace} <- Sheaf.fetch_graph(Sheaf.Repo.workspace_graph()),
         {:ok, docs} <- fetch_document_graphs(doc_iris) do
      excluded = excluded_documents_from_workspace(workspace)

      docs
      |> Enum.map(fn {doc, graph} ->
        description = RDF.Data.description(graph, RDF.iri(doc))

        expression =
          Description.first(description, FABIO.isRepresentationOf())

        expression =
          expression ||
            first_object(metadata, RDF.iri(doc), FABIO.isRepresentationOf())

        authors =
          metadata
          |> objects_for(expression, DCTERMS.creator())
          |> Enum.flat_map(fn
            %RDF.Literal{} = literal ->
              [RDF.Literal.lexical(literal)]

            author ->
              first_object(metadata, author, FOAF.name()) |> List.wrap()
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&term_value/1)
          |> Enum.uniq()
          |> Enum.sort()

        {doc,
         %{
           title:
             document_title(description, metadata, RDF.iri(doc), expression),
           kind:
             document_kind(description, metadata, RDF.iri(doc), expression),
           excluded?: MapSet.member?(excluded, RDF.iri(doc)),
           authors: authors,
           status: document_status(metadata, expression)
         }}
      end)
      |> Map.new()
      |> then(&{:ok, &1})
    end
  end

  defp document_status(_metadata, nil), do: nil

  defp document_status(metadata, expression) do
    status = first_object(metadata, expression, bibo_status())

    (first_object(metadata, status, RDFS.label()) || status)
    |> status_value()
  end

  defp status_value(nil), do: nil

  defp status_value(status) do
    status
    |> term_value()
    |> String.split(["#", "/"])
    |> List.last()
    |> String.replace("-", " ")
    |> String.downcase()
  end

  defp fetch_document_graphs(doc_iris) do
    doc_iris
    |> Enum.reduce_while({:ok, []}, fn doc, {:ok, graphs} ->
      case Sheaf.Corpus.graph_iri(doc) do
        {:ok, graph} -> {:cont, {:ok, [{doc, graph} | graphs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_document_metadata do
    with {:ok, documents} <- Sheaf.Documents.list(include_excluded: true) do
      documents
      |> Map.new(fn document ->
        {
          document.iri,
          %{
            title: document.title,
            kind: document.kind,
            excluded?: document.excluded?,
            authors: Map.get(document.metadata, :authors, [])
          }
        }
      end)
      |> then(&{:ok, &1})
    end
  end

  defp search_loaded(
         conn,
         query_values,
         model,
         dimensions,
         source,
         limit,
         opts
       ) do
    exact_limit =
      Keyword.get(opts, :exact_limit, exact_candidate_limit(limit, opts))

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
           vector_results_until(
             conn,
             query_values,
             model,
             dimensions,
             source,
             limit,
             opts
           ) do
      fused_results = fuse_ranked_results(exact_results, vector_results, opts)

      Tracer.set_attributes([
        {"sheaf.retrieval.lexical_candidate_count", length(exact_results)},
        {"sheaf.retrieval.semantic_candidate_count", length(vector_results)},
        {"sheaf.retrieval.fused_candidate_count", length(fused_results)}
      ])

      {:ok, Enum.take(fused_results, limit)}
    end
  end

  defp vector_results_until(
         conn,
         query_values,
         model,
         dimensions,
         source,
         limit,
         opts
       ) do
    initial_candidate_limit =
      Keyword.get(opts, :candidate_limit, max(limit * 4, 80))

    max_candidate_limit =
      Keyword.get(
        opts,
        :max_candidate_limit,
        max(initial_candidate_limit, 500)
      )

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
           Store.search_vectors(
             conn,
             query_values,
             model,
             dimensions,
             candidate_limit,
             source
           ),
         ranked =
           Enum.filter(ranked, &embedding_variant_allowed?(&1.iri, opts)),
         {:ok, metadata} <-
           sidecar_descriptions_for_iris(
             ranked |> Enum.map(&citation_iri(&1.iri)) |> Enum.uniq(),
             Keyword.merge(opts,
               model: model,
               output_dimensionality: dimensions
             )
           ) do
      results =
        ranked
        |> Enum.flat_map(fn ranked ->
          case Map.get(metadata, citation_iri(ranked.iri)) do
            nil ->
              []

            unit ->
              unit
              |> Map.merge(%{
                score: ranked.score,
                semantic_score: ranked.score,
                lexical_score: 0.0,
                match: :semantic,
                run_iri: ranked.run_iri,
                embedding_variant: embedding_variant(ranked.iri),
                embedding_iri: ranked.iri,
                match_text: semantic_match_text(unit, ranked.iri, opts)
              })
              |> searchable_result(opts)
          end
        end)

      if unique_result_count(results) >= limit or
           candidate_limit >= max_candidate_limit do
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
    search_opts =
      opts
      |> Keyword.take([:db_path, :document_id, :kinds])
      |> Keyword.put(:limit, Keyword.get(opts, :limit, 60))

    with {:ok, hits} <- Sheaf.Search.Index.search(query, search_opts),
         {:ok, metadata} <-
           sidecar_descriptions_for_iris(Enum.map(hits, & &1.iri), opts) do
      {:ok,
       hits
       |> Enum.flat_map(fn hit ->
         metadata
         |> Map.get(hit.iri, hit)
         |> Map.merge(%{
           score: hit.score,
           semantic_score: nil,
           lexical_score: hit.lexical_score,
           match: :exact,
           run_iri: nil
         })
         |> searchable_result(opts)
       end)}
    end
  end

  defp unit_from_sidecar(units, iri, documents, retrieval_contexts) do
    case Map.get(units, iri) do
      nil ->
        nil

      unit ->
        doc = Map.get(documents, unit.doc_iri, %{})
        context = Map.get(retrieval_contexts, unit.iri, %{})

        Map.merge(unit, %{
          doc_title: Map.get(unit, :doc_title) || Map.get(doc, :title),
          doc_kind: Map.get(doc, :kind),
          doc_authors: Map.get(doc, :authors, []),
          doc_status: Map.get(doc, :status),
          doc_excluded?: Map.get(doc, :excluded?, false),
          breadcrumbs: Map.get(context, :breadcrumbs, []),
          previous: Map.get(context, :previous),
          following: Map.get(context, :following)
        })
    end
  end

  defp retrieval_context_metadata(units) do
    units
    |> Map.values()
    |> Enum.reject(&is_nil(&1.doc_iri))
    |> Enum.group_by(& &1.doc_iri)
    |> Enum.flat_map(fn {doc_iri, doc_units} ->
      case Sheaf.Corpus.graph_iri(doc_iri) do
        {:ok, %Graph{} = graph} ->
          hierarchy = Document.hierarchy_index(graph)

          {source_units, document_units} =
            Enum.split_with(doc_units, &(&1.kind == "sourceFile"))

          source_contexts =
            Enum.map(source_units, fn unit ->
              {unit.iri,
               %{
                 breadcrumbs:
                   Document.breadcrumbs(
                     graph,
                     RDF.iri(unit.iri),
                     hierarchy
                   ),
                 previous: nil,
                 following: nil
               }}
            end)

          document_contexts =
            if document_units == [] do
              []
            else
              chunks =
                graph
                |> Document.text_chunks(RDF.iri(doc_iri))
                |> Enum.reject(&(&1.type == :section))

              positions =
                chunks
                |> Enum.with_index()
                |> Map.new(fn {chunk, index} ->
                  {to_string(chunk.iri), index}
                end)

              Enum.map(document_units, fn unit ->
                index = Map.get(positions, unit.iri)

                {unit.iri,
                 %{
                   breadcrumbs:
                     Document.breadcrumbs(
                       graph,
                       RDF.iri(unit.iri),
                       hierarchy
                     ),
                   previous: retrieval_neighbor(chunks, index, -1),
                   following: retrieval_neighbor(chunks, index, 1)
                 }}
              end)
            end

          source_contexts ++ document_contexts

        _error ->
          Enum.map(doc_units, &{&1.iri, %{breadcrumbs: []}})
      end
    end)
    |> Map.new()
  end

  defp retrieval_neighbor(_chunks, nil, _offset), do: nil

  defp retrieval_neighbor(chunks, index, offset) do
    position = index + offset

    case if(position < 0, do: nil, else: Enum.at(chunks, position)) do
      nil ->
        nil

      chunk ->
        %{
          iri: to_string(chunk.iri),
          id: Document.id(chunk.iri),
          text: chunk.text,
          source_page: chunk.source_page,
          type: chunk.type
        }
    end
  end

  defp searchable_result(result, opts) do
    if kind_allowed?(result, opts) and document_allowed?(result, opts) and
         document_kind_allowed?(result, opts) and
         Map.get(result, :doc_excluded?, false) != true and
         searchable_content?(result) and semantic_content_allowed?(result) do
      [result]
    else
      []
    end
  end

  defp semantic_content_allowed?(%{
         match: :semantic,
         source_block_type: "Equation"
       }),
       do: true

  defp semantic_content_allowed?(%{match: :semantic, text: text}),
    do: word_count(text) >= @semantic_min_words

  defp semantic_content_allowed?(_result), do: true

  defp semantic_match_text(%{kind: "sourceFile"} = unit, embedding_iri, opts) do
    case source_file_segment_index(embedding_iri) do
      nil ->
        nil

      index ->
        unit.text
        |> source_file_segments(unit.doc_title, opts)
        |> Enum.at(index)
        |> case do
          %{text: text} -> text
          _other -> nil
        end
    end
  end

  defp semantic_match_text(_unit, _embedding_iri, _opts), do: nil

  defp kind_allowed?(result, opts) do
    result.kind in (opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap())
  end

  defp document_allowed?(result, opts) do
    case Keyword.get(opts, :document_id) do
      nil ->
        true

      "" ->
        true

      document_id ->
        result.doc_iri == document_id |> Sheaf.Id.iri() |> to_string()
    end
  end

  defp document_kind_allowed?(result, opts) do
    case Keyword.get(opts, :document_kind) do
      nil ->
        true

      "" ->
        true

      kind ->
        normalize_kind(Map.get(result, :doc_kind)) == normalize_kind(kind)
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
    String.contains?(text, ";base64,") or
      String.contains?(text, "data:image/")
  end

  defp base64_html?(_text), do: false

  defp word_count(text) when is_binary(text) do
    ~r/[\p{L}\p{N}][\p{L}\p{N}'’-]*/u
    |> Regex.scan(text)
    |> length()
  end

  defp word_count(_text), do: 0

  defp fuse_ranked_results(exact_results, vector_results, opts) do
    rank_constant = Keyword.get(opts, :rrf_rank_constant, 60)

    contributions =
      ranked_contributions(exact_results, :lexical, rank_constant) ++
        ranked_contributions(vector_results, :semantic, rank_constant)

    contributions
    |> Enum.group_by(fn {result, _contribution} -> result.iri end)
    |> Enum.map(fn {_iri, ranked} ->
      {results, scores} = Enum.unzip(ranked)

      results
      |> Enum.reduce(&merge_result/2)
      |> Map.put(:score, Enum.sum(scores))
      |> Map.put(:fusion, :reciprocal_rank)
    end)
    |> Enum.sort_by(&{-&1.score, match_sort(&1), &1.iri})
  end

  defp ranked_contributions(results, channel, rank_constant) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, rank} ->
      weight = fusion_weight(channel, Map.get(result, :embedding_variant))
      {result, weight / (rank_constant + rank)}
    end)
  end

  defp fusion_weight(:lexical, _variant), do: 1.0
  defp fusion_weight(:semantic, :context), do: 0.85
  defp fusion_weight(:semantic, _variant), do: 1.0

  defp unique_result_count(results) do
    results |> Enum.uniq_by(& &1.iri) |> length()
  end

  defp merge_result(left, right) do
    lexical_score =
      max(score_value(left.lexical_score), score_value(right.lexical_score))

    semantic_score =
      max(score_value(left.semantic_score), score_value(right.semantic_score))

    match = merged_match(left.match, right.match)

    Map.merge(left, %{
      score: combined_score(semantic_score, lexical_score, match),
      semantic_score: semantic_score_or_nil(semantic_score),
      lexical_score: lexical_score,
      match: match,
      run_iri: left.run_iri || right.run_iri,
      semantic_variants: merged_semantic_variants(left, right)
    })
  end

  defp merged_semantic_variants(left, right) do
    ([Map.get(left, :embedding_variant), Map.get(right, :embedding_variant)] ++
       Map.get(left, :semantic_variants, []) ++
       Map.get(right, :semantic_variants, []))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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

  defp description_rows_for_iris(iris) do
    wanted = iris |> Enum.map(&RDF.iri/1) |> Enum.uniq()

    with {:ok, subject_rows} <- Sheaf.Repo.match_rows({wanted, nil, nil, nil}),
         {:ok, owner_rows} <-
           Sheaf.Repo.match_rows({nil, DOC.paragraph(), wanted, nil}) do
      owners =
        owner_rows
        |> Enum.map(fn {_g, owner, _p, _o} -> owner end)
        |> Enum.uniq()

      with {:ok, owner_subject_rows} <- rows_for({owners, nil, nil, nil}) do
        {:ok, subject_rows ++ owner_rows ++ owner_subject_rows}
      end
    end
  end

  defp rows_for({[], _predicate, _object, _graph}), do: {:ok, []}
  defp rows_for(pattern), do: Sheaf.Repo.match_rows(pattern)

  defp graph_for_rows(rows, iris) do
    wanted = iris |> Enum.map(&RDF.iri/1) |> MapSet.new()
    paragraph_owners = paragraph_owners(rows, wanted)

    Enum.reduce(rows, Graph.new(), fn {_graph, subject, predicate, object},
                                      graph ->
      if MapSet.member?(wanted, subject) or
           MapSet.member?(paragraph_owners, subject) do
        Graph.add(graph, {subject, predicate, object})
      else
        graph
      end
    end)
  end

  defp paragraph_owners(rows, wanted) do
    rows
    |> Enum.reduce(MapSet.new(), fn
      {_graph, subject, predicate, object}, acc ->
        if predicate == DOC.paragraph() and MapSet.member?(wanted, object) do
          MapSet.put(acc, subject)
        else
          acc
        end
    end)
  end

  defp docs_by_iri(rows, iris) do
    wanted = iris |> Enum.map(&RDF.iri/1) |> MapSet.new()

    rows
    |> Enum.flat_map(fn {graph, subject, _predicate, _object} ->
      if MapSet.member?(wanted, subject) do
        [{term_value(subject), term_value(graph)}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp unit_from_graph(%Graph{} = graph, iri, docs_by_iri, documents) do
    subject = RDF.iri(iri)
    description = RDF.Data.description(graph, subject)
    doc_iri = Map.get(docs_by_iri, iri)

    cond do
      text = first_value(description, Sheaf.NS.DOC.sourceHtml()) ->
        unit_from_description(
          description,
          "sourceHtml",
          text,
          doc_iri,
          documents
        )

      text = first_value(description, Sheaf.NS.DOC.text()) ->
        unit_from_description(description, "row", text, doc_iri, documents)

      paragraph = Description.first(description, Sheaf.NS.DOC.paragraph()) ->
        paragraph_description = RDF.Data.description(graph, paragraph)

        case first_value(paragraph_description, Sheaf.NS.DOC.text()) do
          nil ->
            nil

          text ->
            unit_from_description(
              description,
              "paragraph",
              text,
              doc_iri,
              documents
            )
        end

      true ->
        nil
    end
  end

  defp unit_from_description(
         %Description{} = description,
         kind,
         text,
         doc_iri,
         documents
       ) do
    model = Sheaf.Embedding.model()
    doc = Map.get(documents, doc_iri, %{})
    doc_title = Map.get(doc, :title)

    %{
      iri: description.subject |> RDF.Term.value() |> to_string(),
      kind: kind,
      text: text,
      text_hash:
        text_hash(
          embedding_document_text(text, doc_title, model),
          model,
          @default_dimensions
        ),
      text_chars: String.length(text),
      doc_iri: doc_iri,
      doc_title: doc_title,
      doc_kind: Map.get(doc, :kind),
      doc_authors: Map.get(doc, :authors, []),
      doc_status: Map.get(doc, :status),
      doc_excluded?: Map.get(doc, :excluded?, false),
      source_page:
        description
        |> Description.first(Sheaf.NS.DOC.sourcePage())
        |> integer_value(),
      source_block_type:
        first_value(description, Sheaf.NS.DOC.sourceBlockType()),
      spreadsheet_row:
        description
        |> Description.first(Sheaf.NS.DOC.spreadsheetRow())
        |> integer_value(),
      spreadsheet_source:
        first_value(description, Sheaf.NS.DOC.spreadsheetSource()),
      code_category_title:
        first_value(description, Sheaf.NS.DOC.codeCategoryTitle())
    }
  end

  defp first_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> term_value()
  end

  defp document_title(%Description{} = description, metadata, doc, expression) do
    (Description.first(description, RDFS.label()) ||
       first_object(metadata, doc, RDFS.label()) ||
       first_object(metadata, doc, DCTERMS.title()) ||
       first_object(metadata, expression, DCTERMS.title()) ||
       first_object(metadata, expression, RDFS.label()))
    |> term_value()
  end

  defp document_kind(%Description{} = description, metadata, doc, expression) do
    cond do
      Description.include?(description, {RDF.type(), RDF.iri(DOC.Thesis)}) ->
        :thesis

      Description.include?(description, {RDF.type(), RDF.iri(DOC.Paper)}) ->
        :literature

      Description.include?(description, {RDF.type(), RDF.iri(DOC.Transcript)}) ->
        :transcript

      Description.include?(
        description,
        {RDF.type(), RDF.iri(DOC.Spreadsheet)}
      ) ->
        :spreadsheet

      kind = metadata_document_kind(metadata, doc, expression) ->
        kind

      true ->
        :document
    end
  end

  defp metadata_document_kind(metadata, doc, expression) do
    metadata
    |> objects_for(doc, RDF.type())
    |> Kernel.++(objects_for(metadata, expression, RDF.type()))
    |> Enum.find_value(&metadata_kind/1)
  end

  defp metadata_kind(type) do
    case type
         |> term_value()
         |> to_string()
         |> String.split(["#", "/"])
         |> List.last() do
      "ResearchPaper" -> :literature
      "JournalArticle" -> :literature
      "Book" -> :literature
      "BookChapter" -> :literature
      "Thesis" -> :thesis
      "Spreadsheet" -> :spreadsheet
      "Transcript" -> :transcript
      _other -> nil
    end
  end

  defp exact_candidate_limit(limit, opts) do
    cond do
      Keyword.get(opts, :document_id) not in [nil, ""] ->
        max(limit * 2, 20)

      Keyword.get(opts, :document_kind) in [nil, ""] ->
        max(limit * 4, 60)

      true ->
        max(limit * 20, 500)
    end
  end

  defp normalize_kind(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> normalize_kind()

  defp normalize_kind(kind) when is_binary(kind) do
    case kind |> String.trim() |> String.downcase() do
      "paper" -> "literature"
      kind -> kind
    end
  end

  defp normalize_kind(kind), do: kind |> to_string() |> normalize_kind()

  defp excluded_documents_from_workspace(workspace) do
    excludes_document = DOC.excludesDocument()

    workspace
    |> Graph.triples()
    |> Enum.flat_map(fn
      {_workspace, ^excludes_document, doc} -> [doc]
      _triple -> []
    end)
    |> MapSet.new()
  end

  defp first_object(nil, _subject, _predicate), do: nil
  defp first_object(_graph, nil, _predicate), do: nil

  defp first_object(graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.find_value(fn
      {^subject, ^predicate, object} -> object
      _triple -> nil
    end)
  end

  defp objects_for(nil, _subject, _predicate), do: []
  defp objects_for(_graph, nil, _predicate), do: []

  defp objects_for(graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp bibo_status, do: RDF.iri("http://purl.org/ontology/bibo/status")

  defp integer_value(nil), do: nil

  defp integer_value(term) do
    case RDF.Term.value(term) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        value |> Integer.parse() |> integer_parse_value()

      _ ->
        nil
    end
  end

  defp integer_parse_value({value, _rest}), do: value
  defp integer_parse_value(:error), do: nil

  defp source(opts),
    do:
      Keyword.get(opts, :source, Keyword.get(opts, :profile, @default_source))

  defp embedding_document_text(text, title, model) do
    Sheaf.Embedding.prepared_text(text,
      model: model,
      task: :search,
      input_role: :document,
      title: title
    )
  end
end
