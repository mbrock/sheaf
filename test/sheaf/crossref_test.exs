defmodule Sheaf.CrossrefTest do
  use ExUnit.Case, async: false
  use RDF

  alias RDF.NS.OWL
  alias Sheaf.Crossref
  alias Sheaf.NS.{DCTERMS, DOI, FABIO, FOAF, FRBR}

  setup do
    Req.Test.verify_on_exit!()
  end

  test "fetches Crossref work metadata" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/works/10.1177%2F1749975520923521"
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      Req.Test.json(conn, %{
        "message" => %{
          "DOI" => "10.1177/1749975520923521",
          "title" => ["After Practice?"]
        }
      })
    end)

    assert {:ok, %{"DOI" => "10.1177/1749975520923521", "title" => ["After Practice?"]}} =
             Crossref.work("10.1177/1749975520923521",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "fetches Crossref Turtle from the transform endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/works/10.1177%2F1749975520923521/transform"
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/turtle"]

      conn
      |> Plug.Conn.put_resp_content_type("text/turtle")
      |> Plug.Conn.send_resp(200, """
      <http://dx.doi.org/10.1177/1749975520923521>
        <http://purl.org/dc/terms/title> "After Practice?" .
      """)
    end)

    assert {:ok, turtle} =
             Crossref.turtle("10.1177/1749975520923521",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert turtle =~ "After Practice?"
  end

  test "parses Crossref Turtle into an RDF graph" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/turtle")
      |> Plug.Conn.send_resp(200, """
      <http://dx.doi.org/10.1177/1749975520923521>
        <http://purl.org/dc/terms/title> "After Practice?" .
      """)
    end)

    assert {:ok, graph} =
             Crossref.graph("10.1177/1749975520923521",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert Enum.count(graph) == 1
  end

  test "merges Crossref RDF into a metadata graph with local links" do
    metadata_graph = RDF.Graph.new()
    doi = DOI |> RDF.IRI.coerce_base() |> RDF.IRI.append("10.1177/1749975520923521")
    expression = ~I<https://sheaf.less.rest/FF4RVL>
    paper = ~I<https://sheaf.less.rest/4EFC4F>
    work = ~I<https://sheaf.less.rest/XP3G2H>
    author = ~I<https://id.crossref.org/contributor/david-m-evans-1kle5nn4fd917>
    journal = ~I<https://id.crossref.org/issn/1749-9755>

    crossref_graph =
      RDF.Graph.new([
        {doi, DCTERMS.title(), "After Practice?"},
        {doi, DCTERMS.creator(), author},
        {doi, DCTERMS.isPartOf(), journal},
        {author, FOAF.name(), "David M. Evans"},
        {journal, DCTERMS.title(), "Cultural Sociology"}
      ])

    graph =
      Crossref.merge_metadata_graph(
        metadata_graph,
        crossref_graph,
        " 10.1177/1749975520923521 ",
        crossref_work: %{
          "DOI" => "10.1177/1749975520923521",
          "issue" => "4",
          "page" => "340-356",
          "published-online" => %{"date-parts" => [[2020, 6, 27]]},
          "publisher" => "SAGE Publications",
          "title" => ["After Practice?"],
          "type" => "journal-article",
          "volume" => "14"
        },
        expression: expression,
        paper: paper,
        work: work,
        work_type: FABIO.ResearchPaper
      )

    assert RDF.Data.include?(graph, {
             doi,
             DCTERMS.title(),
             "After Practice?"
           })

    assert RDF.Data.include?(graph, {
             paper,
             FABIO.isRepresentationOf(),
             expression
           })

    assert RDF.Data.include?(graph, {
             paper,
             FABIO.isPortrayalOf(),
             work
           })

    assert RDF.Data.include?(graph, {
             expression,
             FRBR.realizationOf(),
             work
           })

    assert RDF.Data.include?(graph, {
             work,
             RDF.type(),
             RDF.iri(FABIO.ResearchPaper)
           })

    assert RDF.Data.include?(graph, {
             expression,
             RDF.type(),
             RDF.iri(FABIO.JournalArticle)
           })

    assert RDF.Data.include?(graph, {
             expression,
             FABIO.hasPublicationYear(),
             "2020"
           })

    assert RDF.Data.include?(graph, {
             expression,
             FABIO.hasPageRange(),
             "340-356"
           })

    assert RDF.Data.include?(graph, {
             expression,
             DCTERMS.creator(),
             author
           })

    assert RDF.Data.include?(graph, {
             expression,
             OWL.sameAs(),
             doi
           })
  end

  test "mints local expression and work resources for a paper import" do
    paper = ~I<https://sheaf.less.rest/4EFC4F>
    doi = DOI |> RDF.IRI.coerce_base() |> RDF.IRI.append("10.1177/1749975520923521")

    crossref_graph =
      RDF.Graph.new({doi, DCTERMS.title(), "After Practice?"})

    graph =
      Crossref.merge_metadata_graph(
        RDF.Graph.new(),
        crossref_graph,
        "10.1177/1749975520923521",
        crossref_work: %{
          "DOI" => "10.1177/1749975520923521",
          "title" => ["After Practice?"],
          "type" => "journal-article"
        },
        paper: paper
      )

    expression =
      graph
      |> RDF.Graph.query([{paper, FABIO.isRepresentationOf(), :expression?}])
      |> List.first()
      |> Map.fetch!(:expression)

    work =
      graph
      |> RDF.Graph.query([{paper, FABIO.isPortrayalOf(), :work?}])
      |> List.first()
      |> Map.fetch!(:work)

    assert expression != doi
    assert work != doi

    assert RDF.Data.include?(graph, {expression, FRBR.realizationOf(), work})
    assert RDF.Data.include?(graph, {work, RDF.type(), RDF.iri(FABIO.ScholarlyWork)})
    assert RDF.Data.include?(graph, {expression, FABIO.hasDOI(), "10.1177/1749975520923521"})
  end

  test "returns API errors without raising" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.text("Resource not found.")
    end)

    assert {:error, %{status: 404, body: "Resource not found."}} =
             Crossref.work("10.0000/missing", req_options: [plug: {Req.Test, __MODULE__}])
  end
end
