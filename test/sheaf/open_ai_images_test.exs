defmodule Sheaf.OpenAI.ImagesTest do
  use ExUnit.Case, async: true

  alias Sheaf.OpenAI.Images

  test "generates and persists a standalone image with provenance" do
    test_pid = self()

    blob_root =
      Path.join(
        System.tmp_dir!(),
        "sheaf-image-test-#{System.unique_integer()}"
      )

    image_iri = Sheaf.Id.iri("IMG123")

    on_exit(fn -> File.rm_rf(blob_root) end)

    request = fn url, opts ->
      send(test_pid, {:request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => [%{"b64_json" => Base.encode64("png bytes")}]}
       }}
    end

    assert_graph = fn graph ->
      send(test_pid, {:assert_graph, graph})
      :ok
    end

    assert {:ok, result} =
             Images.generate("A luminous paper forest",
               api_key: "test-key",
               request: request,
               image_iri: image_iri,
               blob_root: blob_root,
               assert_graph: assert_graph
             )

    assert result.image_id == "IMG123"
    assert result.path == "/images/IMG123"
    assert result.model == "gpt-image-2"
    assert result.byte_size == byte_size("png bytes")

    assert_received {:request, "https://api.openai.com/v1/images/generations",
                     opts}

    assert opts[:json].model == "gpt-image-2"
    assert opts[:json].size == "1024x1536"
    assert opts[:json].quality == "medium"
    assert opts[:json].output_format == "png"

    assert_received {:assert_graph, graph}
    assert RDF.Data.statement_count(graph) >= 14

    refute Enum.any?(RDF.Graph.triples(graph), fn {_s, p, _o} ->
             p == RDF.iri(Sheaf.NS.DOC.coverImage())
           end)
  end
end
