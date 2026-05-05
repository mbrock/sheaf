defmodule Sheaf.SearchMaintenance do
  @moduledoc """
  Keeps derived search indexes aligned after document graph edits.
  """

  alias Sheaf.{Corpus, DocumentEdits, Id}
  alias Sheaf.Embedding.Index, as: EmbeddingIndex
  alias Sheaf.Search.Index, as: SearchIndex

  @doc """
  Refreshes embedding and FTS search indexes for edited document blocks.

  Section and document ids are expanded to their text-bearing descendants.
  Deleted blocks are tolerated so callers can refresh after destructive edits.
  """
  def refresh_blocks(block_ids) do
    with {:ok, affected_blocks} <- affected_text_block_ids(block_ids),
         {:ok, rows} <- affected_text_rows(affected_blocks),
         affected_iris = MapSet.new(Enum.map(affected_blocks, &(Id.iri(&1) |> to_string()))),
         stale_iris = MapSet.to_list(affected_iris),
         current_search_units = SearchIndex.units_from_rows(rows),
         current_embedding_units = EmbeddingIndex.units_from_rows(rows),
         current_embedding_iris = MapSet.new(Enum.map(current_embedding_units, & &1.iri)),
         embedding_units =
           Enum.filter(current_embedding_units, &MapSet.member?(affected_iris, &1.iri)),
         current_hashes =
           current_embedding_units
           |> Enum.map(&{&1.iri, &1.text_hash})
           |> MapSet.new(),
         {:ok, embedding} <-
           EmbeddingIndex.sync_units(embedding_units,
             current_hashes: current_hashes,
             vector_iris: stale_iris
           ),
         {:ok, search} <- SearchIndex.replace_units(current_search_units, stale_iris) do
      {:ok,
       %{
         block_ids: List.wrap(block_ids),
         affected_blocks: affected_blocks,
         current_blocks:
           current_embedding_iris |> MapSet.to_list() |> Enum.map(&Id.id_from_iri/1),
         embedding: embedding,
         search: search
       }}
    end
  end

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

    affected_iris = MapSet.new(Enum.map(block_ids, &(Id.iri(&1) |> to_string())))

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
