defmodule Sheaf.PDFTest do
  use ExUnit.Case, async: true

  alias RDF.{Description, Graph}
  alias Sheaf.NS.{BIBO, DOC, FABIO}
  alias Sheaf.{Document, PDF}

  test "builds a paper graph from extracted PDF section hierarchy" do
    document = %{
      "children" => [
        %{
          "children" => [
            %{
              "block_type" => "SectionHeader",
              "html" => "<h1>Intro</h1>",
              "id" => "/page/0/SectionHeader/0",
              "page" => 0,
              "section_hierarchy" => %{}
            },
            %{
              "block_type" => "SectionHeader",
              "html" => "<h2>Background</h2>",
              "id" => "/page/0/SectionHeader/1",
              "page" => 0,
              "section_hierarchy" => %{"1" => "/page/0/SectionHeader/0"}
            },
            %{
              "block_type" => "Picture",
              "html" => ~s(<p><img src="figure.png" alt="figure"/></p>),
              "id" => "/page/0/Picture/2",
              "images" => %{"figure.png" => "QUJD"},
              "page" => 0,
              "section_hierarchy" => %{
                "1" => "/page/0/SectionHeader/0",
                "2" => "/page/0/SectionHeader/1"
              }
            }
          ]
        }
      ],
      "metadata" => %{}
    }

    result = PDF.build_graph(document, title: "Example Paper", mint: mint())

    assert Document.kind(result.graph, result.document) == :paper
    assert Document.title(result.graph, result.document) == "Example Paper"
    assert rdf_value(Graph.description(result.graph, result.document), BIBO.numPages()) == 1

    [intro] = Document.children(result.graph, result.document)
    assert Document.block_type(result.graph, intro) == :section
    assert Document.heading(result.graph, intro) == "Intro"

    [background] = Document.children(result.graph, intro)
    assert Document.block_type(result.graph, background) == :section
    assert Document.heading(result.graph, background) == "Background"

    [picture] = Document.children(result.graph, background)
    assert Document.block_type(result.graph, picture) == :extracted
    assert Document.source_page(result.graph, picture) == 0
    assert Document.source_html(result.graph, picture) =~ "data:image/png;base64,QUJD"

    picture_description = Graph.description(result.graph, picture)

    assert rdf_value(picture_description, DOC.sourceKey()) == "/page/0/Picture/2"
    assert rdf_value(picture_description, DOC.sourceBlockType()) == "Picture"
  end

  test "links imported papers to a content-addressed PDF computer file" do
    document = %{"children" => [], "metadata" => %{}}

    result =
      PDF.build_graph(document,
        title: "Example Paper",
        source_file: %{
          byte_size: 123,
          hash: "abc123",
          mime_type: "application/pdf",
          original_filename: "paper.pdf",
          storage_key: "sha256:abc123"
        },
        mint: mint(~w(DOC111 FILE111))
      )

    document = result.document
    file = RDF.IRI.new!("https://example.com/sheaf/FILE111")
    file_description = Graph.description(result.graph, file)

    assert RDF.Data.include?(result.graph, {document, DOC.sourceFile(), file})
    assert Description.include?(file_description, {RDF.type(), FABIO.ComputerFile})
    assert rdf_value(file_description, DOC.sha256()) == "abc123"
    assert rdf_value(file_description, DOC.mimeType()) == "application/pdf"
    assert rdf_value(file_description, DOC.byteSize()) == 123
    assert rdf_value(file_description, DOC.originalFilename()) == "paper.pdf"
    assert rdf_value(file_description, DOC.sourceKey()) == "sha256:abc123"
  end

  test "links imported papers to an existing file entity without duplicating its description" do
    document = %{"children" => [], "metadata" => %{}}
    file = RDF.IRI.new!("https://example.com/sheaf/FILE111")

    result =
      PDF.build_graph(document,
        title: "Example Paper",
        source_file: %{
          byte_size: 123,
          hash: "abc123",
          mime_type: "application/pdf",
          original_filename: "paper.pdf",
          storage_key: "sha256:abc123"
        },
        source_file_iri: file,
        mint: mint(~w(DOC111))
      )

    paper = result.document
    file_description = Graph.description(result.graph, file)

    assert RDF.Data.include?(result.graph, {paper, DOC.sourceFile(), file})
    refute Description.include?(file_description, {RDF.type(), FABIO.ComputerFile})
    refute Description.include?(file_description, {DOC.sha256(), "abc123"})
  end

  test "links imported papers to an existing file entity without source metadata" do
    document = %{"children" => [], "metadata" => %{}}
    file = RDF.IRI.new!("https://example.com/sheaf/FILE111")

    result =
      PDF.build_graph(document,
        title: "Example Paper",
        source_file_iri: file,
        mint: mint(~w(DOC111))
      )

    assert RDF.Data.include?(result.graph, {result.document, DOC.sourceFile(), file})
  end

  test "does not invent a title when the extracted document has none" do
    document = %{"children" => [], "metadata" => %{}}

    result =
      PDF.build_graph(document,
        source_file_iri: RDF.IRI.new!("https://example.com/sheaf/FILE111"),
        mint: mint(~w(DOC111))
      )

    description = Graph.description(result.graph, result.document)

    assert result.title == nil
    refute Description.include?(description, {RDF.NS.RDFS.label(), "Untitled paper"})
    refute Description.first(description, RDF.NS.RDFS.label())
  end

  test "does not use section headings as document titles" do
    document = %{
      "children" => [
        %{
          "children" => [
            %{
              "block_type" => "SectionHeader",
              "html" => "<h1>Looks Like A Title</h1>",
              "id" => "/page/0/SectionHeader/0",
              "page" => 0,
              "section_hierarchy" => %{}
            }
          ]
        }
      ],
      "metadata" => %{}
    }

    result =
      PDF.build_graph(document,
        source_file_iri: RDF.IRI.new!("https://example.com/sheaf/FILE111"),
        mint: mint(~w(DOC111 SEC111 LST111))
      )

    description = Graph.description(result.graph, result.document)

    assert result.title == nil
    refute Description.first(description, RDF.NS.RDFS.label())
  end

  defp rdf_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> RDF.Term.value()
  end

  defp mint(ids \\ ~w(DOC111 SEC111 SEC222 BLK111 LST111 LST222 LST333)) do
    {:ok, agent} =
      Agent.start_link(fn ->
        ids
        |> Enum.map(&RDF.IRI.new!("https://example.com/sheaf/#{&1}"))
      end)

    fn ->
      Agent.get_and_update(agent, fn [iri | rest] -> {iri, rest} end)
    end
  end
end
