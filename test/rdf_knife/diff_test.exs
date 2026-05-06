defmodule RDFKnife.DiffTest do
  use ExUnit.Case, async: true

  alias RDFKnife.Diff

  @patch %{
    "format" => "rdfknife.patch.v1",
    "positive" => """
    <https://example.test/a> <https://example.test/p> "added" .
    <https://example.test/g-s> <https://example.test/p> <https://example.test/o> <https://example.test/g> .
    """,
    "negative" => """
    <https://example.test/a> <https://example.test/p> "old" .
    """
  }

  test "reads simple JSON patch with positive and negative N-Quads datasets" do
    assert {:ok, diff} = Jason.encode!(@patch) |> Diff.read_string()

    assert %{
             format: "rdfknife.patch.v1",
             positive: 2,
             negative: 1,
             graphs: %{
               positive: [
                 {"(default graph)", 1},
                 {"https://example.test/g", 1}
               ],
               negative: [{"(default graph)", 1}]
             }
           } = Diff.summary(diff)
  end

  test "renders SPARQL Update grouped by default and named graphs" do
    diff = Jason.encode!(@patch) |> Diff.read_string() |> elem(1)

    assert Diff.to_sparql!(diff) ==
             """
             DELETE DATA {
               <https://example.test/a> <https://example.test/p> "old" .
             }

             INSERT DATA {
               <https://example.test/a> <https://example.test/p> "added" .
               GRAPH <https://example.test/g> {
                 <https://example.test/g-s> <https://example.test/p> <https://example.test/o> .
               }
             }
             """
             |> String.trim_trailing()
  end

  test "applies a patch to an in-memory dataset" do
    original =
      RDF.NQuads.read_string!("""
      <https://example.test/a> <https://example.test/p> "old" .
      <https://example.test/keep> <https://example.test/p> "same" .
      """)

    diff = Jason.encode!(@patch) |> Diff.read_string() |> elem(1)

    patched = Diff.apply_to_dataset(diff, original)

    assert RDF.Dataset.statement_count(patched) == 3

    assert patched
           |> RDF.NQuads.write_string!()
           |> String.contains?("\"added\"")

    refute patched
           |> RDF.NQuads.write_string!()
           |> String.contains?("\"old\"")
  end

  test "dry-run apply returns summary and update text without calling an update target" do
    diff = Jason.encode!(@patch) |> Diff.read_string() |> elem(1)

    assert {:ok,
            %{
              applied?: false,
              summary: %{positive: 2, negative: 1},
              sparql: sparql
            }} =
             Diff.apply(diff, dry_run: true)

    assert sparql =~ "DELETE DATA"
    assert sparql =~ "INSERT DATA"
  end

  test "apply calls the provided update function" do
    diff = Jason.encode!(@patch) |> Diff.read_string() |> elem(1)
    parent = self()

    assert {:ok, %{applied?: true, summary: %{positive: 2, negative: 1}}} =
             Diff.apply(diff,
               update: fn sparql ->
                 send(parent, {:sparql, sparql})
                 :ok
               end
             )

    assert_receive {:sparql, sparql}
    assert sparql =~ "GRAPH <https://example.test/g>"
  end

  test "rejects unsupported patch formats" do
    assert {:error, {:unsupported_patch_format, "something-else"}} =
             %{@patch | "format" => "something-else"}
             |> Jason.encode!()
             |> Diff.read_string()
  end
end
