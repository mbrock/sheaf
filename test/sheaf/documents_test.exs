defmodule Sheaf.DocumentsTest do
  use ExUnit.Case, async: false
  use RDF

  alias Sheaf.Documents
  alias Sheaf.NS.{DOC, FABIO}

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
        "kind" => RDF.iri(DOC.Paper),
        "excluded" => RDF.literal("true")
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
      },
      %{
        "doc" => ~I<https://example.com/sheaf/CODED>,
        "title" => RDF.literal("Coded spreadsheet"),
        "kind" => RDF.iri(DOC.Spreadsheet)
      }
    ]

    assert [
             %{id: "THESIS", kind: :thesis, path: "/THESIS", title: "Example Thesis"},
             %{
               id: "PAPER1",
               kind: :paper,
               path: "/PAPER1",
               title: "Example Paper",
               excluded?: true
             },
             %{
               id: "23",
               kind: :transcript,
               path: nil,
               title: "Interview 23"
             },
             %{
               id: "CODED",
               kind: :spreadsheet,
               path: "/CODED",
               title: "Coded spreadsheet"
             }
           ] = Documents.from_rows(rows)

    refute Enum.any?(Documents.from_rows(rows, include_excluded: false), &(&1.id == "PAPER1"))
  end

  test "prefers specific document kinds over generic document rows" do
    rows = [
      %{
        "doc" => ~I<https://example.com/sheaf/PAPER1>,
        "title" => RDF.literal("Example Paper"),
        "kind" => RDF.iri(DOC.Document)
      },
      %{
        "doc" => ~I<https://example.com/sheaf/PAPER1>,
        "title" => RDF.literal("Example Paper"),
        "kind" => RDF.iri(DOC.Paper)
      },
      %{
        "doc" => ~I<https://example.com/sheaf/THESIS>,
        "title" => RDF.literal("Example Thesis"),
        "kind" => RDF.iri(DOC.Document)
      },
      %{
        "doc" => ~I<https://example.com/sheaf/THESIS>,
        "title" => RDF.literal("Example Thesis"),
        "kind" => RDF.iri(DOC.Thesis)
      }
    ]

    assert [
             %{id: "THESIS", kind: :thesis},
             %{id: "PAPER1", kind: :paper}
           ] = Documents.from_rows(rows)
  end

  test "falls back to the short id for untitled documents" do
    assert [%{title: "UNTITLED", kind: :document, metadata: %{}, path: "/UNTITLED"}] =
             Documents.from_rows([
               %{"doc" => ~I<https://example.com/sheaf/UNTITLED>}
             ])
  end

  test "aggregates bibliographic metadata from repeated document rows" do
    rows = [
      %{
        "doc" => ~I<https://example.com/sheaf/PAPER1>,
        "title" => RDF.literal("Imported PDF title"),
        "kind" => RDF.iri(DOC.Paper),
        "metadataTitle" => RDF.literal("Article title"),
        "metadataKind" => ~I<http://purl.org/spar/fabio/JournalArticle>,
        "authorName" => RDF.literal("Beta Author"),
        "year" => RDF.literal("2020"),
        "venueTitle" => RDF.literal("Example Journal"),
        "doi" => RDF.literal("10.123/example"),
        "volume" => RDF.literal("14"),
        "issue" => RDF.literal("4"),
        "pages" => RDF.literal("340-356")
      },
      %{
        "doc" => ~I<https://example.com/sheaf/PAPER1>,
        "title" => RDF.literal("Imported PDF title"),
        "kind" => RDF.iri(DOC.Paper),
        "metadataTitle" => RDF.literal("Article title"),
        "metadataKind" => ~I<http://purl.org/spar/fabio/JournalArticle>,
        "authorName" => RDF.literal("Alpha Author"),
        "year" => RDF.literal("2020"),
        "venueTitle" => RDF.literal("Example Journal"),
        "doi" => RDF.literal("10.123/example"),
        "volume" => RDF.literal("14"),
        "issue" => RDF.literal("4"),
        "pages" => RDF.literal("340-356")
      }
    ]

    assert [
             %{
               metadata: %{
                 authors: ["Alpha Author", "Beta Author"],
                 doi: "10.123/example",
                 issue: "4",
                 kind: "Journal article",
                 pages: "340-356",
                 title: "Article title",
                 venue: "Example Journal",
                 volume: "14",
                 year: "2020"
               },
               title: "Article title"
             }
           ] = Documents.from_rows(rows)
  end

  test "builds non-navigable rows for cited metadata-only works" do
    rows = [
      %{
        "doc" => ~I<https://example.com/sheaf/WORK1>,
        "title" => RDF.literal("Metadata-only work"),
        "kind" => RDF.iri(FABIO.ScholarlyWork),
        "metadataKind" => ~I<http://purl.org/spar/fabio/Book>,
        "authorName" => RDF.literal("Example Author"),
        "year" => RDF.literal("1998"),
        "metadataPageCount" => RDF.literal("180"),
        "cited" => RDF.literal("true"),
        "metadataOnly" => RDF.literal("true")
      }
    ]

    assert [
             %{
               id: "WORK1",
               title: "Metadata-only work",
               path: nil,
               cited?: true,
               has_document?: false,
               metadata: %{
                 authors: ["Example Author"],
                 kind: "Book",
                 page_count: 180,
                 year: "1998"
               }
             }
           ] = Documents.from_rows(rows)
  end
end
