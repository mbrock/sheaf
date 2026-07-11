defmodule Sheaf.CorpusSearchTest do
  use ExUnit.Case, async: false

  alias Sheaf.Assistant.ToolResults
  alias Sheaf.CorpusSearch
  alias Sheaf.Id
  alias Sheaf.NS.{C4O, DCTERMS, DOCO, DOC, FABIO, FOAF, FRBR}

  test "search combines exact and approximate literature hits" do
    test_pid = self()

    exact_search = fn query, opts ->
      send(test_pid, {:exact, query, opts})

      {:ok,
       [
         %{
           iri: to_string(Id.iri("BLK111")),
           doc_iri: to_string(Id.iri("DOC111")),
           doc_title: "Shove dynamics",
           doc_authors: ["Elizabeth Shove"],
           doc_status: "mikael",
           kind: "sourceHtml",
           text: "<p>Practices move through materials and meanings.</p>",
           source_page: 12,
           match: :exact,
           score: 1.0
         }
       ]}
    end

    search = fn query, opts ->
      send(test_pid, {:approximate, query, opts})
      {:ok, []}
    end

    assert {:ok, results} =
             CorpusSearch.search("shove dynamics",
               exact_search: exact_search,
               search: search
             )

    assert [hit] = results.exact_results
    assert hit.document_title == "Shove dynamics"
    assert hit.text == "Practices move through materials and meanings."

    assert_received {:exact, "shove dynamics", exact_opts}
    assert exact_opts[:limit] == 10
    refute Keyword.has_key?(exact_opts, :document_kind)

    assert_received {:approximate, "shove dynamics", approximate_opts}
    assert approximate_opts[:exact_limit] == 0
  end

  test "search results carry section and adjacent passage context" do
    result = %{
      iri: to_string(Id.iri("BLK222")),
      doc_iri: to_string(Id.iri("DOC222")),
      doc_title: "Road generation",
      doc_authors: [],
      kind: "sourceHtml",
      text: "<p>The focal road result.</p>",
      source_page: 8,
      breadcrumbs: [%{id: "SEC2", title: "Evaluation", type: :section}],
      previous: %{id: "BLK221", text: "The setup.", source_page: 7},
      following: %{id: "BLK223", text: "The discussion.", source_page: 8},
      match: :semantic,
      score: 0.03
    }

    assert {:ok, results} =
             CorpusSearch.search("road result",
               exact_search: fn _query, _opts -> {:ok, []} end,
               search: fn _query, _opts -> {:ok, [result]} end
             )

    assert [hit] = results.approximate_results
    assert hit.context == result.breadcrumbs
    assert hit.neighbors == [result.previous, result.following]
  end

  test "markdown is concise and omits block ids and scores" do
    long_text = String.duplicate("Practice theory result ", 40)

    {:ok, results} =
      CorpusSearch.search("shove dynamics",
        exact_search: fn _query, _opts ->
          {:ok,
           [
             %{
               iri: to_string(Id.iri("BLK111")),
               doc_iri: to_string(Id.iri("DOC111")),
               doc_title: "Shove dynamics",
               doc_authors: ["Elizabeth Shove"],
               kind: "paragraph",
               text: long_text,
               source_page: nil,
               match: :exact,
               score: 1.0
             }
           ]}
        end,
        search: fn _query, _opts -> {:ok, []} end
      )

    markdown = CorpusSearch.markdown(results, query: "shove dynamics")

    assert markdown =~ "# Corpus results for shove dynamics"
    assert markdown =~ "**Shove dynamics** - Elizabeth Shove"
    assert markdown =~ String.trim(long_text)
    refute markdown =~ " ..."
    refute markdown =~ "BLK111"
    refute markdown =~ "Score"
  end

  test "markdown renders hit breadcrumbs as read links" do
    results = %ToolResults.SearchResults{
      exact_results: [
        %ToolResults.SearchHit{
          document_id: "DOC111",
          document_title: "Example Book",
          document_authors: [],
          block_id: "BLK111",
          kind: :extracted,
          text: "A passage about a tiger in a larger argument.",
          breadcrumbs: [
            %{id: "CHAP11", title: "Interesting Chapter"},
            %{id: "SEC222", title: "Section about Tigers"}
          ],
          match: :exact,
          score: 1.0
        }
      ]
    }

    markdown = CorpusSearch.markdown(results, query: "tiger")

    assert markdown =~
             "[Interesting Chapter](https://sheaf.less.rest/read/CHAP11) > [Section about Tigers](https://sheaf.less.rest/read/SEC222)"
  end

  test "turtle selects fabio realization metadata and anonymous quote paragraphs" do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-search-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    doc = Id.iri("DOC111")
    block = Id.iri("BLK111")
    expression = Id.iri("EXPR11")
    work = Id.iri("WORK11")
    author = RDF.iri("https://id.example/author/shove")

    venue =
      RDF.iri(
        "https://id.example/venue/#{System.unique_integer([:positive])}"
      )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), DOC.Paper},
                   {doc, RDF.NS.RDFS.label(), "Local paper label"},
                   {block, RDF.type(), DOC.ExtractedBlock},
                   {block, DOC.sourceHtml(),
                    "<p>Practices move through materials.</p>"},
                   {block, DOC.sourcePage(), 12}
                 ],
                 name: doc
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, FABIO.isRepresentationOf(), expression},
                   {doc, FABIO.isPortrayalOf(), work},
                   {expression, RDF.type(), FABIO.ResearchPaper},
                   {expression, RDF.NS.RDFS.label(), "After Practice?"},
                   {expression, DCTERMS.title(), "After Practice?"},
                   {expression, DCTERMS.creator(), author},
                   {expression, DCTERMS.isPartOf(), venue},
                   {expression, FABIO.hasDOI(), "10.1177/example"},
                   {expression, FRBR.realizationOf(), work},
                   {work, RDF.type(), FABIO.ScholarlyWork},
                   {work, DCTERMS.title(), "After Practice?"},
                   {author, RDF.type(), FOAF.Person},
                   {author, FOAF.name(), "Elizabeth Shove"},
                   {author, FOAF.givenName(), "Elizabeth"},
                   {author, FOAF.familyName(), "Shove"},
                   {venue, RDF.type(), FABIO.JournalArticle}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    results = %ToolResults.SearchResults{
      exact_results: [
        %ToolResults.SearchHit{
          document_id: "DOC111",
          document_title: "After Practice?",
          block_id: "BLK111",
          kind: :extracted,
          text:
            "Practices move through materials in everyday life, and this sentence contains enough words to survive the filter without relying on terminal punctuation.",
          source_page: 12,
          match: :exact,
          score: 1.0
        }
      ]
    }

    turtle = CorpusSearch.turtle(results, query: "practice")
    assert turtle =~ "@prefix : <https://sheaf.less.rest/>"
    assert turtle =~ "@prefix dcterms:"
    assert turtle =~ "@prefix bibo:"
    assert turtle =~ "@prefix fabio:"
    assert turtle =~ "@prefix prism:"
    assert turtle =~ "@prefix owl:"
    assert turtle =~ "@prefix foaf:"
    assert turtle =~ "@prefix c4o:"
    assert turtle =~ "@prefix doco:"

    refute turtle =~ "# Corpus results"
    refute turtle =~ "activitystreams"
    refute turtle =~ "rdf:_1"
    refute turtle =~ "Score"
    refute turtle =~ "BLK111"
    refute turtle =~ "DOC111"
    refute turtle =~ "WORK11"
    refute turtle =~ "rdfs:label"
    refute turtle =~ "frbr:realizationOf"
    assert turtle =~ "dcterms:isPartOf"

    assert {:ok, graph} = RDF.read_string(turtle, media_type: "text/turtle")

    assert RDF.Data.include?(
             graph,
             {expression, DCTERMS.title(), RDF.literal("After Practice?")}
           )

    assert RDF.Data.include?(
             graph,
             {expression, FABIO.hasDOI(), RDF.literal("10.1177/example")}
           )

    same_as = RDF.NS.OWL.sameAs()

    [author_blank] =
      graph
      |> RDF.Graph.triples()
      |> Enum.flat_map(fn
        {blank, ^same_as, ^author} -> [blank]
        _triple -> []
      end)

    assert %RDF.BlankNode{} = author_blank

    assert RDF.Data.include?(
             graph,
             {author_blank, RDF.type(), RDF.iri(FOAF.Person)}
           )

    assert RDF.Data.include?(
             graph,
             {author_blank, FOAF.name(), RDF.literal("Elizabeth Shove")}
           )

    refute RDF.Data.include?(
             graph,
             {author, FOAF.name(), RDF.literal("Elizabeth Shove")}
           )

    refute turtle =~ "foaf:givenName"
    refute turtle =~ "foaf:familyName"

    refute RDF.Data.include?(
             graph,
             {expression, RDF.NS.RDFS.label(), RDF.literal("After Practice?")}
           )

    refute RDF.Data.include?(
             graph,
             {expression, FRBR.realizationOf(), work}
           )

    assert RDF.Data.include?(
             graph,
             {expression, DCTERMS.isPartOf(), venue}
           )

    refute RDF.Data.include?(
             graph,
             {venue, RDF.type(), RDF.iri(FABIO.JournalArticle)}
           )

    [paragraph] = objects_for(graph, expression, DCTERMS.hasPart())

    assert %RDF.BlankNode{} = paragraph

    assert RDF.Data.include?(
             graph,
             {paragraph, RDF.type(), RDF.iri(DOCO.Paragraph)}
           )

    assert RDF.Data.include?(
             graph,
             {paragraph, C4O.hasContent(),
              RDF.literal(
                "Practices move through materials in everyday life, and this sentence contains enough words to survive the filter without relying on terminal punctuation."
              )}
           )

    refute RDF.Data.include?(
             graph,
             {block, DOC.sourceHtml(),
              RDF.literal("<p>Practices move through materials.</p>")}
           )

    refute RDF.Data.include?(
             graph,
             {doc, FABIO.isRepresentationOf(), expression}
           )
  end

  test "turtle empty prefix follows configured resource base" do
    previous = Application.get_env(:sheaf, :resource_base)

    Application.put_env(
      :sheaf,
      :resource_base,
      "https://example.org/resources/"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:sheaf, :resource_base, previous)
      else
        Application.delete_env(:sheaf, :resource_base)
      end
    end)

    turtle =
      CorpusSearch.turtle(%ToolResults.SearchResults{}, query: "anything")

    assert turtle =~ "@prefix : <https://example.org/resources/>"
    refute turtle =~ "@prefix : <https://sheaf.less.rest/>"
  end

  test "turtle renders all hits supplied by search" do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-search-fragment-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    doc = Id.iri("DOC111")
    expression = Id.iri("EXPR11")
    fragment_doc = Id.iri("DOC222")
    fragment_expression = Id.iri("EXPR22")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, FABIO.isRepresentationOf(), expression},
                   {expression, RDF.type(), FABIO.Book},
                   {expression, DCTERMS.title(), "Example Book"},
                   {fragment_doc, FABIO.isRepresentationOf(),
                    fragment_expression},
                   {fragment_expression, RDF.type(), FABIO.Book},
                   {fragment_expression, DCTERMS.title(), "Fragment Book"}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    results = %ToolResults.SearchResults{
      exact_results: [
        %ToolResults.SearchHit{
          document_id: "DOC222",
          document_title: "Fragment Book",
          block_id: "BLK111",
          kind: :extracted,
          text: "TURKEY TOLSON",
          match: :exact,
          score: 1.0
        },
        %ToolResults.SearchHit{
          document_id: "DOC222",
          document_title: "Fragment Book",
          block_id: "BLK112",
          kind: :extracted,
          text: "Dr. Seuss, West Beast East Beast",
          match: :exact,
          score: 0.95
        },
        %ToolResults.SearchHit{
          document_id: "DOC111",
          document_title: "Example Book",
          block_id: "BLK222",
          kind: :extracted,
          text:
            "This is a useful sentence with enough words to pass the twenty word minimum filter in the response graph without checking punctuation.",
          match: :exact,
          score: 0.9
        }
      ]
    }

    turtle = CorpusSearch.turtle(results, query: "turkey")
    assert {:ok, graph} = RDF.read_string(turtle, media_type: "text/turtle")

    paragraphs = objects_for(graph, expression, DCTERMS.hasPart())
    assert length(paragraphs) == 1

    fragment_paragraphs =
      objects_for(graph, fragment_expression, DCTERMS.hasPart())

    assert length(fragment_paragraphs) == 2

    assert RDF.Data.include?(
             graph,
             {expression, DCTERMS.title(), RDF.literal("Example Book")}
           )

    assert turtle =~
             "This is a useful sentence with enough words to pass the twenty word minimum filter in the response graph without checking punctuation."

    assert turtle =~ "TURKEY TOLSON"
    assert turtle =~ "Dr. Seuss"
    assert turtle =~ "Fragment Book"

    assert RDF.Data.include?(
             graph,
             {fragment_expression, DCTERMS.title(),
              RDF.literal("Fragment Book")}
           )
  end

  defp objects_for(graph, subject, predicate) do
    graph
    |> RDF.Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end
end
