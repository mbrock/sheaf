defmodule Sheaf.SearchMaintenance do
  @moduledoc """
  Keeps derived search indexes aligned after document graph edits.
  """

  alias Sheaf.{Corpus, DocumentEdits, Id}
  alias Sheaf.Embedding.Index, as: EmbeddingIndex
  alias Sheaf.Search.Index, as: SearchIndex

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Refreshes only the derived search units changed by a Git synchronization.

  Source-file rows are read from the repository's small current-text graph.
  Newly discovered commits are loaded by subject from the immutable repository
  graph. Deleted source units remain in `stale_iris` so their sidecar rows and
  vectors are removed.
  """
  def refresh_git_sync(git_summary, opts \\ []) do
    source_iris = Map.get(git_summary, :changed_source_file_iris, [])
    commit_iris = Map.get(git_summary, :new_commit_iris, [])
    stale_iris = Enum.uniq(source_iris ++ commit_iris)

    Tracer.with_span "Sheaf.SearchMaintenance.refresh_git_sync", %{
      kind: :internal,
      attributes: [
        {"sheaf.git.repository", to_string(git_summary.repository)},
        {"sheaf.search.source_file_count", length(source_iris)},
        {"sheaf.search.commit_count", length(commit_iris)},
        {"sheaf.search.stale_count", length(stale_iris)}
      ]
    } do
      cond do
        stale_iris == [] ->
          {:ok, %{affected_iris: [], embedding: nil, search: nil}}

        not Keyword.get(opts, :sync_search?, true) and
            not Keyword.get(opts, :sync_embeddings?, true) ->
          {:ok, %{affected_iris: stale_iris, embedding: nil, search: nil}}

        true ->
          with {:ok, source_rows} <-
                 current_source_rows(git_summary.repository, source_iris),
               {:ok, commit_rows} <-
                 current_commit_rows(git_summary.repository, commit_iris),
               {:ok, result} <-
                 refresh_rows(source_rows ++ commit_rows, stale_iris, opts) do
            Tracer.set_attributes([
              {"sheaf.search.current_row_count",
               length(source_rows) + length(commit_rows)},
              {"sheaf.search.embedding_target_count",
               (result.embedding && result.embedding.target_count) || 0},
              {"sheaf.search.fts_row_count",
               (result.search && result.search.count) || 0}
            ])

            {:ok, Map.put(result, :affected_iris, stale_iris)}
          end
      end
    end
  end

  @doc """
  Refreshes embedding and FTS search indexes for edited document blocks.

  Section and document ids are expanded to their text-bearing descendants.
  Deleted blocks are tolerated so callers can refresh after destructive edits.
  """
  def refresh_blocks(block_ids) do
    with {:ok, affected_blocks} <- affected_text_block_ids(block_ids),
         {:ok, rows} <- affected_text_rows(affected_blocks),
         affected_iris =
           MapSet.new(Enum.map(affected_blocks, &(Id.iri(&1) |> to_string()))),
         stale_iris = MapSet.to_list(affected_iris),
         current_search_units = SearchIndex.units_from_rows(rows),
         current_embedding_units = EmbeddingIndex.units_from_rows(rows),
         current_embedding_iris =
           MapSet.new(Enum.map(current_embedding_units, & &1.iri)),
         embedding_units =
           Enum.filter(
             current_embedding_units,
             &MapSet.member?(affected_iris, &1.iri)
           ),
         current_hashes =
           current_embedding_units
           |> Enum.map(&{&1.iri, &1.text_hash})
           |> MapSet.new(),
         {:ok, embedding} <-
           EmbeddingIndex.sync_units(embedding_units,
             current_hashes: current_hashes,
             vector_iris: stale_iris
           ),
         {:ok, search} <-
           SearchIndex.replace_units(current_search_units, stale_iris) do
      {:ok,
       %{
         block_ids: List.wrap(block_ids),
         affected_blocks: affected_blocks,
         current_blocks:
           current_embedding_iris
           |> MapSet.to_list()
           |> Enum.map(&Id.id_from_iri/1),
         embedding: embedding,
         search: search
       }}
    end
  end

  @doc """
  Refreshes embedding and FTS search indexes for persisted research notes.
  """
  def refresh_notes(note_ids) do
    note_ids =
      note_ids |> List.wrap() |> Enum.map(&Id.id_from_iri/1) |> Enum.uniq()

    note_iris = note_ids |> Enum.map(&(Id.iri(&1) |> to_string()))
    affected_iris = MapSet.new(note_iris)

    with {:ok, rows} <- Sheaf.TextUnits.fetch_rows(kinds: ["note"]) do
      rows =
        Enum.filter(rows, fn row ->
          row
          |> Map.fetch!("iri")
          |> RDF.Term.value()
          |> to_string()
          |> then(&MapSet.member?(affected_iris, &1))
        end)

      search_units = SearchIndex.units_from_rows(rows)
      embedding_units = EmbeddingIndex.units_from_rows(rows)

      current_hashes =
        embedding_units |> Enum.map(&{&1.iri, &1.text_hash}) |> MapSet.new()

      with {:ok, embedding} <-
             EmbeddingIndex.sync_units(embedding_units,
               current_hashes: current_hashes,
               vector_iris: note_iris
             ),
           {:ok, search} <- SearchIndex.replace_units(search_units, note_iris) do
        {:ok,
         %{
           note_ids: note_ids,
           embedding: embedding,
           search: search
         }}
      end
    end
  end

  defp refresh_rows(rows, stale_iris, opts) do
    search_units = SearchIndex.units_from_rows(rows)
    embedding_units = EmbeddingIndex.units_from_rows(rows, opts)

    current_hashes =
      embedding_units |> Enum.map(&{&1.iri, &1.text_hash}) |> MapSet.new()

    with {:ok, embedding} <-
           maybe_refresh_embeddings(
             embedding_units,
             stale_iris,
             current_hashes,
             opts
           ),
         {:ok, search} <-
           maybe_refresh_search(search_units, stale_iris, opts) do
      {:ok, %{embedding: embedding, search: search}}
    end
  end

  defp maybe_refresh_embeddings(units, stale_iris, current_hashes, opts) do
    if Keyword.get(opts, :sync_embeddings?, true) do
      EmbeddingIndex.sync_units(
        units,
        Keyword.merge(opts,
          current_hashes: current_hashes,
          vector_citation_iris: stale_iris
        )
      )
    else
      {:ok, nil}
    end
  end

  defp maybe_refresh_search(units, stale_iris, opts) do
    if Keyword.get(opts, :sync_search?, true) do
      SearchIndex.replace_units(units, stale_iris, opts)
    else
      {:ok, nil}
    end
  end

  defp current_source_rows(_repository, []), do: {:ok, []}

  defp current_source_rows(repository, iris) do
    requested = MapSet.new(iris)

    with {:ok, graph} <- Corpus.graph_iri(repository) do
      rows =
        graph
        |> RDF.dataset()
        |> Sheaf.TextUnits.rows(kinds: ["sourceFile"])
        |> Enum.filter(&MapSet.member?(requested, term_string(&1["iri"])))

      {:ok, rows}
    end
  end

  defp current_commit_rows(_repository, []), do: {:ok, []}

  defp current_commit_rows(repository, iris) do
    subjects = Enum.map(iris, &RDF.iri/1)

    with {:ok, dataset} <-
           Sheaf.Repo.match({subjects, nil, nil, RDF.iri(repository)}) do
      {:ok, Sheaf.TextUnits.rows(dataset, kinds: ["gitCommit"])}
    end
  end

  defp term_string(term), do: term |> RDF.Term.value() |> to_string()

  defp affected_text_block_ids(block_ids) do
    block_ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn block_id, {:ok, affected} ->
      case DocumentEdits.text_block_ids([block_id]) do
        {:ok, []} ->
          {:cont, {:ok, MapSet.put(affected, block_id)}}

        {:ok, ids} ->
          {:cont, {:ok, Enum.reduce(ids, affected, &MapSet.put(&2, &1))}}

        {:error, reason} when is_binary(reason) ->
          if String.ends_with?(reason, " not found") do
            {:cont, {:ok, MapSet.put(affected, block_id)}}
          else
            {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, affected} -> {:ok, MapSet.to_list(affected)}
      error -> error
    end
  end

  defp affected_text_rows([]), do: {:ok, []}

  defp affected_text_rows(block_ids) do
    document_ids =
      block_ids
      |> Corpus.find_documents()
      |> Map.values()
      |> Enum.uniq()

    affected_iris =
      MapSet.new(Enum.map(block_ids, &(Id.iri(&1) |> to_string())))

    document_ids
    |> Enum.reduce_while({:ok, []}, fn document_id, {:ok, rows} ->
      case Sheaf.fetch_graph(Id.iri(document_id)) do
        {:ok, graph} ->
          graph_rows =
            graph
            |> RDF.dataset()
            |> Sheaf.TextUnits.rows(kinds: ["paragraph", "row", "sourceHtml"])
            |> Enum.filter(fn row ->
              row
              |> Map.fetch!("iri")
              |> RDF.Term.value()
              |> to_string()
              |> then(&MapSet.member?(affected_iris, &1))
            end)

          {:cont, {:ok, rows ++ graph_rows}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
