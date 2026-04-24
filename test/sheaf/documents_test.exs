defmodule Sheaf.DocumentsTest do
  use ExUnit.Case, async: false
  use RDF

  alias Sheaf.Documents
  alias Sheaf.NS.DOC

  setup do
    previous = Application.get_env(:sheaf, :resource_base)
    Application.put_env(:sheaf, :resource_base, "https://example.com/sheaf/")

    on_exit(fn ->
      if previous do
        Application.put_env(:sheaf, :resource_base, previous)
      else
        Application.delete_env(:sheaf, :resource_base)
      end
    end)
  end

  test "builds navigable document rows from SPARQL results" do
    rows = [
      %{
        "doc" => ~I<https://example.com/sheaf/PAPER1>,
        "title" => RDF.literal("Example Paper"),
        "kind" => RDF.iri(DOC.Paper)
      },
      %{
        "doc" => ~I<https://example.com/sheaf/interviews/23>,
        "title" => RDF.literal("Interview 23"),
        "kind" => RDF.iri(DOC.Transcript)
      },
      %{
        "doc" => ~I<https://example.com/sheaf/THESIS>,
        "title" => RDF.literal("Example Thesis"),
        "kind" => RDF.iri(DOC.Thesis)
      }
    ]

    assert [
             %{id: "THESIS", kind: :thesis, path: "/THESIS", title: "Example Thesis"},
             %{id: "PAPER1", kind: :paper, path: "/PAPER1", title: "Example Paper"},
             %{
               id: "23",
               kind: :transcript,
               path: nil,
               title: "Interview 23"
             }
           ] = Documents.from_rows(rows)
  end

  test "falls back to the short id for untitled documents" do
    assert [%{title: "UNTITLED", kind: :document, path: "/UNTITLED"}] =
             Documents.from_rows([
               %{"doc" => ~I<https://example.com/sheaf/UNTITLED>}
             ])
  end
end
