defmodule Sheaf.Retrieval.Evaluation do
  @moduledoc """
  Runs small, reviewable retrieval evaluation suites.

  Cases identify a query and an expected text fragment. Block IRIs are not used
  as ground truth because reimporting a document intentionally remints blocks.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @default_limit 10

  def run_file(path, opts \\ []) do
    with {:ok, json} <- File.read(path),
         {:ok, suite} <- Jason.decode(json) do
      run(suite, opts)
    end
  end

  def run(%{"cases" => cases} = suite, opts) when is_list(cases) do
    search = Keyword.get(opts, :search, &Sheaf.Embedding.Index.search/2)
    limit = Keyword.get(opts, :limit, @default_limit)

    Tracer.with_span "Sheaf.Retrieval.Evaluation.run", %{
      kind: :internal,
      attributes: [
        {"sheaf.retrieval.suite", Map.get(suite, "name", "unnamed")},
        {"sheaf.retrieval.case_count", length(cases)},
        {"sheaf.retrieval.limit", limit}
      ]
    } do
      results = Enum.map(cases, &evaluate_case(&1, search, limit, opts))
      found = Enum.count(results, & &1.found)

      report = %{
        name: Map.get(suite, "name", "unnamed"),
        case_count: length(results),
        found_count: found,
        hit_rate: ratio(found, length(results)),
        mean_reciprocal_rank:
          results |> Enum.map(& &1.reciprocal_rank) |> mean(),
        cases: results
      }

      Tracer.set_attributes([
        {"sheaf.retrieval.found_count", found},
        {"sheaf.retrieval.hit_rate", report.hit_rate},
        {"sheaf.retrieval.mean_reciprocal_rank", report.mean_reciprocal_rank}
      ])

      {:ok, report}
    end
  end

  def run(_suite, _opts), do: {:error, :invalid_retrieval_suite}

  defp evaluate_case(test_case, search, limit, opts) do
    query = Map.fetch!(test_case, "query")
    expected = test_case |> Map.fetch!("expected_text") |> normalize()

    search_opts =
      [limit: limit]
      |> maybe_put(:document_id, Map.get(test_case, "document_id"))
      |> maybe_put(:db_path, Keyword.get(opts, :db_path))

    case search.(query, search_opts) do
      {:ok, hits} ->
        rank =
          hits
          |> Enum.find_index(fn hit ->
            hit
            |> Map.get(:text, "")
            |> normalize()
            |> String.contains?(expected)
          end)
          |> case do
            nil -> nil
            index -> index + 1
          end

        %{
          query: query,
          expected_text: Map.fetch!(test_case, "expected_text"),
          document_id: Map.get(test_case, "document_id"),
          found: not is_nil(rank),
          rank: rank,
          reciprocal_rank: if(rank, do: 1.0 / rank, else: 0.0),
          returned_count: length(hits)
        }

      {:error, reason} ->
        %{
          query: query,
          expected_text: Map.fetch!(test_case, "expected_text"),
          document_id: Map.get(test_case, "document_id"),
          found: false,
          rank: nil,
          reciprocal_rank: 0.0,
          returned_count: 0,
          error: inspect(reason)
        }
    end
  end

  defp normalize(text) do
    text
    |> to_string()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ratio(_value, 0), do: 0.0
  defp ratio(value, count), do: value / count
  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
