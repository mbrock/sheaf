defmodule Sheaf.OpenAI.CoverImagesTest do
  use ExUnit.Case, async: true

  alias Sheaf.OpenAI.CoverImages

  test "calls the image generation endpoint and persists provenance" do
    test_pid = self()

    blob_root =
      Path.join(
        System.tmp_dir!(),
        "sheaf-cover-test-#{System.unique_integer()}"
      )

    on_exit(fn -> File.rm_rf(blob_root) end)

    request = fn url, opts ->
      send(test_pid, {:request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => [%{"b64_json" => Base.encode64("png bytes")}]}
       }}
    end

    transact = fn changes ->
      send(test_pid, {:transact, changes})
      :ok
    end

    assert {:ok, result} =
             CoverImages.generate("DOC123", "A luminous paper forest",
               api_key: "test-key",
               request: request,
               resolver: fn "DOC123" -> {:ok, %{kind: :document}} end,
               blob_root: blob_root,
               old_links: [],
               transact: transact
             )

    assert result.path == "/covers/DOC123"
    assert result.model == "gpt-image-2"
    assert result.byte_size == byte_size("png bytes")

    assert_received {:request, "https://api.openai.com/v1/images/generations",
                     opts}

    assert opts[:json].model == "gpt-image-2"
    assert opts[:json].size == "1024x1536"
    assert opts[:json].quality == "medium"
    assert opts[:json].output_format == "png"

    assert_received {:transact, [{:assert, graph}]}
    assert RDF.Data.statement_count(graph) >= 15
  end
end
