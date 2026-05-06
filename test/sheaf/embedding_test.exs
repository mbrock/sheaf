defmodule Sheaf.EmbeddingTest do
  use ExUnit.Case, async: false

  alias Sheaf.Embedding

  setup do
    Req.Test.verify_on_exit!()
  end

  test "posts raw embedContent requests for text" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/v1beta/models/gemini-embedding-2:embedContent"

      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["secret"]

      assert %{
               "content" => %{"parts" => [%{"text" => "A paragraph."}]},
               "output_dimensionality" => 768
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{"embedding" => %{"values" => [0.1, 0.2, 0.3]}})
    end)

    assert {:ok,
            %{
              dimensions: 3,
              model: "gemini-embedding-2",
              values: [0.1, 0.2, 0.3]
            }} =
             Embedding.embed_text("A paragraph.",
               provider: :gemini,
               api_key: "secret",
               output_dimensionality: 768,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "embeds text lists with batchEmbedContents" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path ==
               "/v1beta/models/gemini-embedding-2:batchEmbedContents"

      assert %{
               "requests" => [
                 %{
                   "model" => "models/gemini-embedding-2",
                   "content" => %{"parts" => [%{"text" => "First."}]}
                 },
                 %{
                   "model" => "models/gemini-embedding-2",
                   "content" => %{"parts" => [%{"text" => "Second."}]}
                 }
               ]
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{
        "embeddings" => [
          %{"values" => [1.0]},
          %{"values" => [2.0]}
        ]
      })
    end)

    assert {:ok, [%{values: [1.0]}, %{values: [2.0]}]} =
             Embedding.embed_texts(["First.", "Second."],
               provider: :gemini,
               model: "gemini-embedding-2",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "embeds OpenAI text with embeddings endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/embeddings"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer openai-secret"
             ]

      assert %{
               "model" => "text-embedding-3-small",
               "input" => "A paragraph.",
               "dimensions" => 768
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{
        "data" => [
          %{"embedding" => [0.1, 0.2, 0.3], "index" => 0}
        ]
      })
    end)

    assert {:ok,
            %{
              dimensions: 3,
              model: "text-embedding-3-small",
              values: [0.1, 0.2, 0.3]
            }} =
             Embedding.embed_text("A paragraph.",
               provider: :openai,
               model: "text-embedding-3-small",
               api_key: "openai-secret",
               output_dimensionality: 768,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "embeds OpenAI document batches as input arrays" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/embeddings"

      assert %{
               "model" => "text-embedding-3-small",
               "input" => ["First.", "Second."]
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{
        "data" => [
          %{"embedding" => [1.0], "index" => 0},
          %{"embedding" => [2.0], "index" => 1}
        ]
      })
    end)

    assert {:ok, [%{values: [1.0]}, %{values: [2.0]}]} =
             Embedding.embed_texts(["First.", "Second."],
               provider: :openai,
               model: "text-embedding-3-small",
               api_key: "openai-secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "embeds documents with async Batch API inline requests" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/v1beta/models/gemini-embedding-001:asyncBatchEmbedContent"

      assert %{
               "batch" => %{
                 "inputConfig" => %{
                   "requests" => %{
                     "requests" => [
                       %{
                         "metadata" => %{"key" => "doc-1"},
                         "request" => %{
                           "model" => "models/gemini-embedding-001",
                           "content" => %{"parts" => [%{"text" => "First."}]}
                         }
                       }
                     ]
                   }
                 }
               }
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{
        "name" => "batches/test",
        "metadata" => %{
          "name" => "batches/test",
          "state" => "BATCH_STATE_PENDING"
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1beta/batches/test"

      Req.Test.json(conn, %{
        "name" => "batches/test",
        "metadata" => %{
          "name" => "batches/test",
          "state" => "BATCH_STATE_SUCCEEDED",
          "output" => %{
            "inlinedResponses" => %{
              "inlinedResponses" => [
                %{"response" => %{"embedding" => %{"values" => [1, 2]}}}
              ]
            }
          }
        }
      })
    end)

    assert {:ok, [%{values: [1.0, 2.0]}]} =
             Embedding.async_batch_embed_documents(
               [%{key: "doc-1", text: "First."}],
               api_key: "secret",
               model: "gemini-embedding-001",
               batch_input: :inline,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "translates search task for gemini embedding 2" do
    assert %{
             content: %{
               parts: [
                 %{text: "task: search result | query: plastic"}
               ]
             }
           } =
             Embedding.request_body(
               [
                 %{
                   text:
                     Embedding.prepared_text("plastic",
                       model: "gemini-embedding-2",
                       task: :search,
                       input_role: :query
                     )
                 }
               ],
               model: "gemini-embedding-2",
               task: :search,
               input_role: :query
             )
  end

  test "translates search task for gemini embedding 001" do
    assert %{
             content: %{parts: [%{text: "Plastic text."}]},
             taskType: "RETRIEVAL_DOCUMENT",
             title: "Document title"
           } =
             Embedding.request_body([%{text: "Plastic text."}],
               model: "gemini-embedding-001",
               task: :search,
               input_role: :document,
               title: "Document title"
             )
  end

  test "accepts API embeddings list response shape" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"embeddings" => [%{"values" => [3, 4]}]})
    end)

    assert {:ok, %{values: [3.0, 4.0], dimensions: 2}} =
             Embedding.embed_text("Text.",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "returns a useful error when the API key is missing" do
    previous = Application.get_env(:sheaf, Embedding)
    Application.put_env(:sheaf, Embedding, api_key: nil)

    try do
      assert {:error, :missing_openai_api_key} =
               Embedding.embed_text("No key.")
    after
      if previous do
        Application.put_env(:sheaf, Embedding, previous)
      else
        Application.delete_env(:sheaf, Embedding)
      end
    end
  end

  test "returns a useful error when the OpenAI API key is missing" do
    previous = Application.get_env(:sheaf, Embedding)
    Application.put_env(:sheaf, Embedding, openai_api_key: nil)

    try do
      assert {:error, :missing_openai_api_key} =
               Embedding.embed_text("No key.",
                 provider: :openai,
                 model: "text-embedding-3-small"
               )
    after
      if previous do
        Application.put_env(:sheaf, Embedding, previous)
      else
        Application.delete_env(:sheaf, Embedding)
      end
    end
  end
end
