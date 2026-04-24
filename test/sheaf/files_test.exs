defmodule Sheaf.FilesTest do
  use ExUnit.Case, async: true

  alias RDF.Description
  alias Sheaf.Files
  require RDF.Graph

  test "stores a PDF as a content-addressed RDF computer file" do
    path = Path.join(System.tmp_dir!(), "sheaf-files-test.pdf")
    File.write!(path, "%PDF-1.7\n")

    file_iri = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    activity_iri = RDF.IRI.new!("https://example.com/sheaf/ACT111")
    generated_at = ~U[2026-04-24 10:00:00Z]
    test_pid = self()

    assert {:ok, ^file_iri} =
             Files.create(path,
               filename: "paper.pdf",
               file_iri: file_iri,
               activity_iri: activity_iri,
               generated_at: generated_at,
               put_graph: fn graph_name, graph ->
                 send(test_pid, {:put_graph, graph_name, graph})
                 :ok
               end
             )

    assert_receive {:put_graph, ^file_iri, graph}

    file_description = RDF.Graph.description(graph, file_iri)
    activity_description = RDF.Graph.description(graph, activity_iri)

    assert Description.include?(file_description, {RDF.type(), Sheaf.NS.FABIO.ComputerFile})
    assert Description.include?(file_description, {RDF.type(), Sheaf.NS.PROV.Entity})
    assert rdf_value(file_description, Sheaf.NS.DOC.originalFilename()) == "paper.pdf"
    assert rdf_value(file_description, Sheaf.NS.DOC.mimeType()) == "application/pdf"
    assert Description.include?(file_description, {Sheaf.NS.PROV.wasGeneratedBy(), activity_iri})
    assert rdf_value(file_description, Sheaf.NS.PROV.generatedAtTime()) == generated_at
    assert Description.include?(activity_description, {RDF.type(), Sheaf.NS.PROV.Activity})

    File.rm(path)
  end

  test "returns ComputerFile descriptions newest first" do
    file = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    older = RDF.IRI.new!("https://example.com/sheaf/FILE10")
    document = RDF.IRI.new!("https://example.com/sheaf/DOC111")

    graph =
      RDF.Graph.build file: file, older: older, document: document do
        @prefix Sheaf.NS.DOC
        @prefix Sheaf.NS.FABIO
        @prefix Sheaf.NS.PROV
        @prefix RDF.NS.RDFS

        file
        |> a(FABIO.ComputerFile)
        |> RDFS.label("paper.pdf")
        |> DOC.sha256("abc123")
        |> DOC.sourceKey("sha256:abc123")
        |> DOC.mimeType("application/pdf")
        |> DOC.byteSize(123)
        |> PROV.generatedAtTime(~U[2026-04-24 10:00:00Z])

        older
        |> a(FABIO.ComputerFile)
        |> RDFS.label("older.pdf")
        |> PROV.generatedAtTime(~U[2026-04-23 10:00:00Z])

        document
        |> RDFS.label("A paper")
        |> DOC.sourceFile(file)
      end

    assert [file_description, older_description] = Files.descriptions(graph)
    assert file_description.subject == file
    assert older_description.subject == older
    assert rdf_value(file_description, Sheaf.NS.DOC.sourceKey()) == "sha256:abc123"
    assert rdf_value(file_description, Sheaf.NS.DOC.byteSize()) == 123
  end

  defp rdf_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> RDF.Term.value()
  end
end
