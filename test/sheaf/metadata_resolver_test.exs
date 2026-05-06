defmodule Sheaf.MetadataResolverTest do
  use ExUnit.Case, async: true

  alias Sheaf.MetadataResolver
  require RDF.Graph

  test "builds missing metadata candidates from source files and blob metadata" do
    doc = RDF.IRI.new!("https://sheaf.less.rest/DOC1")
    file = RDF.IRI.new!("https://sheaf.less.rest/FILE1")
    hash = "7ed3de68bfb86919be10d3cad1761b1883b7d09456358e2c38f7b7bb7913afda"
    generated_at = ~U[2026-04-25 12:00:00Z]

    files_graph =
      RDF.Graph.build file: file, hash: hash, generated_at: generated_at do
        @prefix Sheaf.NS.DOC
        @prefix Sheaf.NS.FABIO
        @prefix Sheaf.NS.PROV
        @prefix RDF.NS.RDFS

        file
        |> a(FABIO.ComputerFile)
        |> RDFS.label("paper.pdf")
        |> DOC.sha256(hash)
        |> DOC.mimeType("application/pdf")
        |> DOC.byteSize(1234)
        |> DOC.originalFilename("paper.pdf")
        |> PROV.generatedAtTime(generated_at)
      end

    rows = [
      %{"doc" => doc, "file" => file},
      %{
        "doc" => RDF.IRI.new!("https://sheaf.less.rest/DOC2"),
        "file" => file,
        "expression" => RDF.IRI.new!("https://sheaf.less.rest/EXP2")
      }
    ]

    assert [
             %{
               document: ^doc,
               file: ^file,
               original_filename: "paper.pdf",
               mime_type: "application/pdf",
               byte_size: 1234,
               sha256: ^hash,
               generated_at: ~U[2026-04-25 12:00:00Z]
             } = candidate
           ] = MetadataResolver.candidates_from(rows, files_graph)

    assert candidate.path =~ "priv/blobs/sha256/7e/d3/"
    assert candidate.path =~ "#{hash}.pdf"
  end

  test "resolver uses injected metadata extraction before Crossref matching" do
    path = Path.join(System.tmp_dir!(), "sheaf-metadata-resolver.pdf")
    File.write!(path, "%PDF")

    candidate = %{
      document: RDF.IRI.new!("https://sheaf.less.rest/DOC1"),
      file: RDF.IRI.new!("https://sheaf.less.rest/FILE1"),
      path: path
    }

    test_pid = self()

    extract_metadata = fn seen_candidate, opts ->
      send(
        test_pid,
        {:extract_metadata, seen_candidate.document, opts[:pdf_fallback]}
      )

      {:ok,
       Sheaf.PaperMetadata.normalize_object(%{
         "title" => "No Identifier Yet",
         "authors" => [],
         "doi" => "",
         "isbn" => ""
       })}
    end

    assert {:ok, %{wrote?: false, match: %{reason: "no DOI or ISBN found"}}} =
             MetadataResolver.resolve(candidate,
               pdf_fallback: false,
               extract_metadata: extract_metadata
             )

    assert_receive {:extract_metadata, %RDF.IRI{} = document, false}
    assert to_string(document) == "https://sheaf.less.rest/DOC1"
  after
    File.rm(Path.join(System.tmp_dir!(), "sheaf-metadata-resolver.pdf"))
  end
end
