defmodule Sheaf.Tools.PDFPageBoundaryDryRun do
  @moduledoc false

  require OpenTelemetry.Tracer, as: Tracer

  @predicates %{
    source_html: "https://less.rest/sheaf/sourceHtml",
    source_block_type: "https://less.rest/sheaf/sourceBlockType",
    source_page: "https://less.rest/sheaf/sourcePage",
    source_key: "https://less.rest/sheaf/sourceKey",
    label: "http://www.w3.org/2000/01/rdf-schema#label"
  }

  @terminal_punctuation ~r/[.!?][\]\"”’)]*$/u

  def run(opts \\ []) do
    path = Keyword.get_lazy(opts, :path, &Sheaf.Repo.path/0)
    progress_every = Keyword.get(opts, :progress_every, 5_000)
    examples = Keyword.get(opts, :examples, 12)

    Tracer.with_span "sheaf.pdf_page_boundary_dry_run", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.name", path},
        {"sheaf.progress_every", progress_every}
      ]
    } do
      IO.puts("Scanning Quadlog directly: #{path}")

      initial = %{
        blocks: %{},
        labels: %{},
        rows: 0,
        predicate_rows: %{}
      }

      with {:ok, state} <- stream_rows(path, initial, progress_every) do
        summary = summarize(state, examples)
        set_summary_attributes(summary)
        print_summary(summary)
        {:ok, summary}
      end
    end
  end

  defp stream_rows(path, state, progress_every) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        Enum.reduce_while(@predicates, {:ok, state}, fn {key, predicate}, {:ok, state} ->
          Tracer.add_event("sheaf.pdf_page_boundary_dry_run.predicate_start", %{
            "sheaf.predicate_key" => Atom.to_string(key),
            "sheaf.predicate" => predicate
          })

          with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, rows_sql()),
               :ok <- Exqlite.Sqlite3.bind(statement, [predicate]) do
            try do
              case stream_row_chunks(conn, statement, state, progress_every, key, 0) do
                {:ok, state} ->
                  Tracer.add_event("sheaf.pdf_page_boundary_dry_run.predicate_done", %{
                    "sheaf.predicate_key" => Atom.to_string(key),
                    "sheaf.predicate" => predicate,
                    "sheaf.row_count" => get_in(state, [:predicate_rows, key]) || 0,
                    "sheaf.total_rows" => state.rows
                  })

                  {:cont, {:ok, state}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
            after
              Exqlite.Sqlite3.release(conn, statement)
            end
          else
            {:error, reason} -> {:halt, {:error, reason}}
            error -> {:halt, error}
          end
        end)
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp stream_row_chunks(conn, statement, state, progress_every, predicate_key, chunk_index) do
    case Exqlite.Sqlite3.multi_step(conn, statement, 1_000) do
      {:rows, rows} ->
        state = handle_rows(state, rows)
        emit_progress_span(state, rows, progress_every, predicate_key, chunk_index)
        stream_row_chunks(conn, statement, state, progress_every, predicate_key, chunk_index + 1)

      {:done, rows} ->
        state = handle_rows(state, rows)
        emit_progress_span(state, rows, progress_every, predicate_key, chunk_index)
        {:ok, state}

      :busy ->
        {:error, :busy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_rows(state, rows) do
    Enum.reduce(rows, state, fn [graph, subject, predicate, object], state ->
      state
      |> Map.update!(:rows, &(&1 + 1))
      |> update_in([:predicate_rows, predicate_key(predicate)], &((&1 || 0) + 1))
      |> put_row(predicate_key(predicate), graph, subject, object)
    end)
  end

  defp put_row(state, :label, _graph, subject, object),
    do: update_in(state.labels, &Map.put_new(&1, subject, object))

  defp put_row(state, key, graph, subject, object) do
    block_key = {graph, subject}

    update_in(state.blocks, fn blocks ->
      initial =
        %{graph: graph, subject: subject}
        |> Map.put(key, object)

      Map.update(blocks, block_key, initial, fn block ->
        Map.put(block, key, object)
      end)
    end)
  end

  defp emit_progress_span(_state, [], _progress_every, _predicate_key, _chunk_index), do: :ok

  defp emit_progress_span(state, rows, progress_every, predicate_key, chunk_index) do
    if progress_every > 0 and
         (rem(state.rows, progress_every) < length(rows) or chunk_index == 0) do
      IO.puts("  streamed #{state.rows} rows total")
    end

    Tracer.with_span "sheaf.pdf_page_boundary_dry_run.chunk", %{
      kind: :internal,
      attributes: [
        {"sheaf.chunk_index", chunk_index},
        {"sheaf.predicate_key", Atom.to_string(predicate_key)},
        {"sheaf.chunk_row_count", length(rows)},
        {"sheaf.streamed_rows", state.rows},
        {"sheaf.block_count", map_size(state.blocks)},
        {"sheaf.label_count", map_size(state.labels)}
      ]
    } do
      :ok
    end
  end

  defp rows_sql do
    """
    SELECT g.value, s.value, p.value, o.value
    FROM quads q
    JOIN terms g ON q.graph_id = g.id
    JOIN terms s ON q.subject_id = s.id
    JOIN terms p ON q.predicate_id = p.id
    JOIN terms o ON q.object_id = o.id
    WHERE p.value = ?
    """
  end

  defp predicate_key(predicate) do
    Enum.find_value(@predicates, fn {key, value} ->
      if value == predicate, do: key
    end)
  end

  defp summarize(state, example_count) do
    blocks =
      state.blocks
      |> Map.values()
      |> Enum.filter(&text_block?/1)
      |> Enum.map(&normalize_block/1)

    {boundary_pairs, terminal_pairs, candidates, capital_start} =
      blocks
      |> Enum.group_by(& &1.graph)
      |> Enum.reduce({0, 0, [], 0}, fn {graph, graph_blocks},
                                       {boundary_pairs, terminal_pairs, candidates, capital_start} ->
        graph_blocks = Enum.sort_by(graph_blocks, &{&1.page || -1, &1.index || -1, &1.source_key || "", &1.subject})

        graph_blocks
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce({boundary_pairs, terminal_pairs, candidates, capital_start}, fn
          [%{page: page} = left, %{page: next_page} = right], acc
          when is_integer(page) and next_page == page + 1 ->
            {boundary_pairs, terminal_pairs, candidates, capital_start} = acc
            terminal? = terminal?(left.text)

            candidates =
              if strong_candidate?(left.text, right.text) do
                [%{graph: graph, title: Map.get(state.labels, graph), left: left, right: right} | candidates]
              else
                candidates
              end

            capital_start =
              if not terminal? and Regex.match?(~r/^[[:upper:]]/u, right.text) do
                capital_start + 1
              else
                capital_start
              end

            {boundary_pairs + 1, terminal_pairs + if(terminal?, do: 1, else: 0), candidates, capital_start}

          _pair, acc ->
            acc
        end)
      end)

    candidates = Enum.reverse(candidates)

    %{
      streamed_rows: state.rows,
      predicate_rows: state.predicate_rows,
      documents: blocks |> Enum.map(& &1.graph) |> MapSet.new() |> MapSet.size(),
      text_blocks: length(blocks),
      adjacent_page_boundary_pairs: boundary_pairs,
      boundary_pairs_ending_sentence: terminal_pairs,
      strong_continuation_candidates: length(candidates),
      docs_with_candidates: candidates |> Enum.map(& &1.graph) |> MapSet.new() |> MapSet.size(),
      no_terminal_capital_start: capital_start,
      hyphenated_candidates: Enum.count(candidates, &hyphenated_candidate?/1),
      examples: Enum.take(candidates, example_count),
      top_documents: top_documents(candidates, state.labels, 12)
    }
  end

  defp text_block?(%{source_html: html} = block) when is_binary(html) do
    Map.get(block, :source_block_type) in [nil, "Text"]
  end

  defp text_block?(_block), do: false

  defp normalize_block(block) do
    %{
      graph: block.graph,
      subject: block.subject,
      source_key: Map.get(block, :source_key),
      source_block_type: Map.get(block, :source_block_type),
      page: block |> Map.get(:source_page) |> parse_int(),
      index: block |> Map.get(:source_key) |> text_index(),
      text: block |> Map.fetch!(:source_html) |> plain_text()
    }
  end

  defp top_documents(candidates, labels, count) do
    candidates
    |> Enum.frequencies_by(& &1.graph)
    |> Enum.sort_by(fn {_graph, n} -> -n end)
    |> Enum.take(count)
    |> Enum.map(fn {graph, n} ->
      %{graph: graph, title: Map.get(labels, graph), candidates: n}
    end)
  end

  defp strong_candidate?(left, right) do
    String.length(left) > 40 and
      String.length(right) > 40 and
      not terminal?(left) and
      Regex.match?(~r/^[[:lower:](]/u, right)
  end

  defp hyphenated_candidate?(%{left: %{text: left}, right: %{text: right}}) do
    Regex.match?(~r/[[:alpha:]]-$/u, left) and Regex.match?(~r/^[[:lower:]]/u, right)
  end

  defp terminal?(text), do: Regex.match?(@terminal_punctuation, text)

  defp plain_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/iu, " ")
    |> String.replace(~r/<[^>]*>/u, " ")
    |> html_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp text_index(value) when is_binary(value) do
    case Regex.run(~r/\/Text\/([0-9]+)/, value) do
      [_, index] -> parse_int(index)
      _ -> nil
    end
  end

  defp text_index(_value), do: nil

  defp print_summary(summary) do
    IO.puts("")
    IO.puts("Dry-run summary")
    IO.puts("  streamed rows: #{summary.streamed_rows}")
    IO.puts("  text blocks: #{summary.text_blocks}")
    IO.puts("  documents: #{summary.documents}")
    IO.puts("  adjacent page-boundary pairs: #{summary.adjacent_page_boundary_pairs}")
    IO.puts("  boundary pairs ending sentence: #{summary.boundary_pairs_ending_sentence}")
    IO.puts("  strong continuation candidates: #{summary.strong_continuation_candidates}")
    IO.puts("  docs with candidates: #{summary.docs_with_candidates}")
    IO.puts("  no-terminal capital-start pairs: #{summary.no_terminal_capital_start}")
    IO.puts("  hyphenated candidates: #{summary.hyphenated_candidates}")

    IO.puts("")
    IO.puts("Top documents")

    Enum.each(summary.top_documents, fn doc ->
      IO.puts("  #{doc.candidates}  #{doc.title || doc.graph}")
    end)

    IO.puts("")
    IO.puts("Examples")

    Enum.each(summary.examples, fn example ->
      IO.puts("")
      IO.puts("  #{example.title || example.graph} page #{example.left.page}")
      IO.puts("  #{example.left.source_key} -> #{example.right.source_key}")
      IO.puts("  ... #{String.slice(example.left.text, max(String.length(example.left.text) - 160, 0), 160)}")
      IO.puts("  #{String.slice(example.right.text, 0, 160)} ...")
    end)
  end

  defp set_summary_attributes(summary) do
    Tracer.set_attributes([
      {"sheaf.streamed_rows", summary.streamed_rows},
      {"sheaf.text_block_count", summary.text_blocks},
      {"sheaf.document_count", summary.documents},
      {"sheaf.page_boundary_pair_count", summary.adjacent_page_boundary_pairs},
      {"sheaf.page_boundary_terminal_pair_count", summary.boundary_pairs_ending_sentence},
      {"sheaf.page_boundary_candidate_count", summary.strong_continuation_candidates},
      {"sheaf.page_boundary_candidate_document_count", summary.docs_with_candidates},
      {"sheaf.page_boundary_hyphenated_candidate_count", summary.hyphenated_candidates}
    ])

    Tracer.add_event("sheaf.pdf_page_boundary_dry_run.summary", %{
      "sheaf.streamed_rows" => summary.streamed_rows,
      "sheaf.text_block_count" => summary.text_blocks,
      "sheaf.document_count" => summary.documents,
      "sheaf.page_boundary_pair_count" => summary.adjacent_page_boundary_pairs,
      "sheaf.page_boundary_candidate_count" => summary.strong_continuation_candidates,
      "sheaf.page_boundary_candidate_document_count" => summary.docs_with_candidates
    })
  end
end
