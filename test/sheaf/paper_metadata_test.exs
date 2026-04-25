defmodule Sheaf.PaperMetadataTest do
  use ExUnit.Case, async: true

  alias RDF.NS.RDFS
  alias ReqLLM.Message
  alias Sheaf.PaperMetadata
  alias Sheaf.NS.DOC

  test "extracts PDF metadata with ReqLLM" do
    path = Path.join(System.tmp_dir!(), "sheaf-paper-metadata-test.pdf")
    File.write!(path, "%PDF-1.7\n")

    test_pid = self()

    generate_object = fn model, message, schema, opts ->
      send(test_pid, {:request, model, message, schema, opts})

      {:ok,
       %{
         object: %{
           "title" => "After Practice?",
           "authors" => ["David M. Evans", ""],
           "doi" => "https://doi.org/10.1177/1749975520923521.",
           "isbn" => "ISBN 978-1-4522-6015-1",
           "year" => "2020",
           "publication" => "Cultural Sociology",
           "volume" => "14",
           "issue" => "4",
           "pages" => "340-356",
           "confidence" => "high",
           "notes" => ""
         },
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end

    assert {:ok, metadata} =
             PaperMetadata.extract_pdf(path, generate_object: generate_object)

    assert metadata.title == "After Practice?"
    assert metadata.authors == ["David M. Evans"]
    assert metadata.doi == "10.1177/1749975520923521"
    assert metadata.isbn == "9781452260151"
    assert metadata.publication == "Cultural Sociology"
    assert metadata.model == PaperMetadata.default_model()
    assert metadata.source_filename == "sheaf-paper-metadata-test.pdf"
    assert metadata.usage == %{input_tokens: 10, output_tokens: 5}

    assert_receive {:request, model, %Message{} = message, schema, opts}
    assert model == PaperMetadata.default_model()
    assert Keyword.has_key?(schema, :doi)
    assert Keyword.has_key?(schema, :isbn)
    assert Keyword.has_key?(schema, :title)
    assert Keyword.has_key?(schema, :authors)
    refute Keyword.has_key?(opts, :temperature)
    assert opts[:max_tokens] == 4_096
    assert opts[:provider_options] == []
    assert opts[:receive_timeout] == 120_000

    assert [file_part, prompt_part] = message.content
    assert file_part.type == :file
    assert file_part.filename == "sheaf-paper-metadata-test.pdf"
    assert file_part.media_type == "application/pdf"
    assert file_part.data == "%PDF-1.7\n"
    assert prompt_part.type == :text
    assert prompt_part.text =~ "basic bibliographic metadata"
  after
    File.rm(Path.join(System.tmp_dir!(), "sheaf-paper-metadata-test.pdf"))
  end

  test "extracts PDF metadata from bytes and allows request option overrides" do
    generate_object = fn _model, _message, _schema, opts ->
      refute Keyword.has_key?(opts, :temperature)
      assert opts[:max_tokens] == 4_096
      assert opts[:reasoning_effort] == :medium
      refute Keyword.has_key?(opts[:provider_options], :thinking)
      assert opts[:receive_timeout] == 5_000

      {:ok,
       %{
         "title" => "A Paper",
         "authors" => "One Author",
         "doi" => "DOI: 10.1000/XYZ"
       }}
    end

    assert {:ok, metadata} =
             PaperMetadata.extract_pdf_binary("%PDF", "paper.pdf",
               generate_object: generate_object,
               max_tokens: 4_096,
               reasoning_effort: :medium,
               thinking: false,
               receive_timeout: 5_000,
               provider_options: [custom: true]
             )

    assert metadata.title == "A Paper"
    assert metadata.authors == ["One Author"]
    assert metadata.doi == "10.1000/xyz"
  end

  test "extracts metadata from text without attaching a PDF" do
    test_pid = self()

    generate_object = fn _model, message, _schema, _opts ->
      send(test_pid, {:message, message})

      {:ok,
       %{
         "title" => "Text Paper",
         "authors" => ["A. Author"],
         "doi" => "10.1000/text"
       }}
    end

    assert {:ok, metadata} =
             PaperMetadata.extract_text(
               "Title page\n\nDOI: 10.1000/TEXT\n\nThis paper uses document analysis.",
               generate_object: generate_object
             )

    assert metadata.title == "Text Paper"
    assert metadata.doi == "10.1000/text"

    assert_receive {:message, %Message{} = message}
    assert [prompt_part, text_part] = message.content
    assert prompt_part.type == :text
    assert prompt_part.text =~ "provided academic paper text"
    assert text_part.type == :text
    assert text_part.text =~ "DOI: 10.1000/TEXT"
    refute Enum.any?(message.content, &(&1.type == :file))
  end

  test "extracts metadata from document graph text chunks" do
    paper = RDF.IRI.new!("https://example.com/sheaf/PAPER1")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LSTROOT")
    section = RDF.IRI.new!("https://example.com/sheaf/SEC1")
    block = RDF.IRI.new!("https://example.com/sheaf/BLK1")

    graph =
      RDF.Graph.new([
        {paper, RDF.type(), DOC.Document},
        {paper, RDF.type(), DOC.Paper},
        {paper, DOC.children(), root_list},
        {section, RDF.type(), DOC.Section},
        {section, RDFS.label(), RDF.literal("Introduction")},
        {block, RDF.type(), DOC.ExtractedBlock},
        {block, DOC.sourceHtml(),
         RDF.literal("<p>Paper DOI: 10.1000/GRAPH and practice theory.</p>")}
      ])
      |> then(fn graph -> RDF.list([section, block], graph: graph, head: root_list).graph end)

    test_pid = self()

    generate_object = fn _model, message, _schema, _opts ->
      send(test_pid, {:text, List.last(message.content).text})

      {:ok,
       %{
         "title" => "Graph Paper",
         "authors" => [],
         "doi" => "10.1000/graph"
       }}
    end

    assert {:ok, metadata} =
             PaperMetadata.extract_graph(graph, paper, generate_object: generate_object)

    assert metadata.title == "Graph Paper"
    assert metadata.doi == "10.1000/graph"

    assert_receive {:text, text}
    assert text =~ "Introduction"
    assert text =~ "Paper DOI: 10.1000/GRAPH and practice theory."
  end

  test "returns a useful error for empty text" do
    assert {:error, :empty_text} = PaperMetadata.extract_text(" \n\n ")
  end

  test "returns file read errors without calling the model" do
    missing_path = Path.join(System.tmp_dir!(), "missing-sheaf-paper-metadata-test.pdf")

    generate_object = fn _model, _message, _schema, _opts ->
      flunk("Gemini should not be called for a missing file")
    end

    assert {:error, :enoent} =
             PaperMetadata.extract_pdf(missing_path, generate_object: generate_object)
  end

  test "passes model errors through" do
    generate_object = fn _model, _message, _schema, _opts -> {:error, :quota_exceeded} end

    assert {:error, :quota_exceeded} =
             PaperMetadata.extract_pdf_binary("%PDF", "paper.pdf",
               generate_object: generate_object
             )
  end
end
