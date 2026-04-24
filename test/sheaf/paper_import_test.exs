defmodule Sheaf.PaperImportTest do
  use ExUnit.Case, async: true

  alias RDF.{Description, Graph}
  alias Sheaf.NS.DOC
  alias Sheaf.{PaperImport, Thesis}

  test "builds a paper graph from Datalab JSON section hierarchy" do
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

    result = PaperImport.build_graph(document, title: "Example Paper", mint: mint())

    assert Thesis.kind(result.graph, result.document) == :paper
    assert Thesis.title(result.graph, result.document) == "Example Paper"

    [intro] = Thesis.children(result.graph, result.document)
    assert Thesis.block_type(result.graph, intro) == :section
    assert Thesis.heading(result.graph, intro) == "Intro"

    [background] = Thesis.children(result.graph, intro)
    assert Thesis.block_type(result.graph, background) == :section
    assert Thesis.heading(result.graph, background) == "Background"

    [picture] = Thesis.children(result.graph, background)
    assert Thesis.block_type(result.graph, picture) == :extracted
    assert Thesis.source_page(result.graph, picture) == 0
    assert Thesis.source_html(result.graph, picture) =~ "data:image/png;base64,QUJD"

    picture_description = Graph.description(result.graph, picture)

    assert rdf_value(picture_description, DOC.sourceKey()) == "/page/0/Picture/2"
    assert rdf_value(picture_description, DOC.sourceBlockType()) == "Picture"
  end

  defp rdf_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> RDF.Term.value()
  end

  defp mint do
    {:ok, agent} =
      Agent.start_link(fn ->
        ~w(DOC111 SEC111 SEC222 BLK111 LST111 LST222 LST333)
        |> Enum.map(&RDF.IRI.new!("https://example.com/sheaf/#{&1}"))
      end)

    fn ->
      Agent.get_and_update(agent, fn [iri | rest] -> {iri, rest} end)
    end
  end
end
