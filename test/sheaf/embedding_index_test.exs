defmodule Sheaf.Embedding.IndexTest do
  use ExUnit.Case, async: true

  alias Sheaf.Embedding.Index

  test "builds text units from all text-bearing block shapes" do
    select = fn sparql ->
      assert sparql =~ "sheaf:paragraph"
      assert sparql =~ "sheaf:sourceHtml"
      assert sparql =~ "sheaf:Row"

      {:ok,
       %{
         results: [
           %{
             "iri" => RDF.iri("https://sheaf.less.rest/BLOCK1"),
             "kind" => RDF.literal("paragraph"),
             "text" => RDF.literal("Paragraph text.")
           },
           %{
             "iri" => RDF.iri("https://sheaf.less.rest/BLOCK2"),
             "kind" => RDF.literal("sourceHtml"),
             "text" => RDF.literal("<p>PDF text.</p>")
           },
           %{
             "iri" => RDF.iri("https://sheaf.less.rest/ROW1"),
             "kind" => RDF.literal("row"),
             "text" => RDF.literal("Spreadsheet text.")
           }
         ]
       }}
    end

    assert {:ok, [paragraph, source, row]} =
             Index.text_units(
               select: select,
               model: "gemini-embedding-2",
               output_dimensionality: 768
             )

    assert paragraph.kind == "paragraph"
    assert source.text == "<p>PDF text.</p>"
    assert row.iri == "https://sheaf.less.rest/ROW1"
    assert String.length(row.text_hash) == 64
  end

  test "can restrict text unit kinds" do
    select = fn sparql ->
      assert sparql =~ "sheaf:sourceHtml"
      refute sparql =~ "sheaf:paragraph"
      refute sparql =~ "sheaf:Row"

      {:ok, %{results: []}}
    end

    assert {:ok, []} = Index.text_units(kinds: ["sourceHtml"], select: select)
  end
end
