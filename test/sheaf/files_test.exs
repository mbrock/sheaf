defmodule Sheaf.FilesTest do
  use ExUnit.Case, async: true

  alias RDF.Description
  alias Sheaf.Files
  alias Sheaf.NS.{DOC, FABIO, PROV}

  test "stores a PDF as a content-addressed RDF computer file" do
    path = Path.join(System.tmp_dir!(), "sheaf-files-test.pdf")
    File.write!(path, "%PDF-1.7\n")

    file_iri = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    activity_iri = RDF.IRI.new!("https://example.com/sheaf/ACT111")
    generated_at = ~U[2026-04-24 10:00:00Z]
    test_pid = self()

    assert {:ok, file} =
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

    assert %{id: "FILE11", filename: "paper.pdf", mime_type: "application/pdf"} = file
    assert_receive {:put_graph, ^file_iri, graph}

    file_description = RDF.Graph.description(graph, file_iri)
    activity_description = RDF.Graph.description(graph, activity_iri)

    assert Description.include?(file_description, {RDF.type(), FABIO.ComputerFile})
    assert Description.include?(file_description, {RDF.type(), PROV.Entity})
    assert rdf_value(file_description, DOC.originalFilename()) == "paper.pdf"
    assert rdf_value(file_description, DOC.mimeType()) == "application/pdf"
    assert Description.include?(file_description, {PROV.wasGeneratedBy(), activity_iri})
    assert rdf_value(file_description, PROV.generatedAtTime()) == generated_at
    assert Description.include?(activity_description, {RDF.type(), PROV.Activity})

    File.rm(path)
  end

  test "builds file rows from ComputerFile bindings" do
    file = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    graph = RDF.IRI.new!("https://example.com/sheaf/FILE11")

    rows = [
      %{
        "file" => file,
        "graph" => graph,
        "label" => RDF.literal("paper.pdf"),
        "name" => RDF.literal("paper.pdf"),
        "hash" => RDF.literal("abc123"),
        "key" => RDF.literal("sha256:abc123"),
        "mime" => RDF.literal("application/pdf"),
        "bytes" => RDF.literal(123),
        "generatedAt" => RDF.literal("2026-04-24T10:00:00Z")
      }
    ]

    assert [
             %{
               id: "FILE11",
               filename: "paper.pdf",
               sha256: "abc123",
               source_key: "sha256:abc123",
               mime_type: "application/pdf",
               byte_size: 123,
               standalone?: true
             }
           ] = Files.from_rows(rows)
  end

  defp rdf_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> RDF.Term.value()
  end
end
