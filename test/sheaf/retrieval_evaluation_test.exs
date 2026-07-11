defmodule Sheaf.Retrieval.EvaluationTest do
  use ExUnit.Case, async: true

  alias Sheaf.Retrieval.Evaluation

  test "reports hit rate and reciprocal rank from stable text evidence" do
    suite = %{
      "name" => "test suite",
      "cases" => [
        %{"query" => "alpha", "expected_text" => "target passage"},
        %{"query" => "beta", "expected_text" => "missing passage"}
      ]
    }

    search = fn
      "alpha", opts ->
        assert opts[:limit] == 5

        {:ok,
         [
           %{text: "unrelated"},
           %{text: "<p>The target passage is second.</p>"}
         ]}

      "beta", _opts ->
        {:ok, [%{text: "still unrelated"}]}
    end

    assert {:ok, report} = Evaluation.run(suite, search: search, limit: 5)
    assert report.found_count == 1
    assert report.hit_rate == 0.5
    assert report.mean_reciprocal_rank == 0.25
    assert Enum.map(report.cases, & &1.rank) == [2, nil]
  end
end
