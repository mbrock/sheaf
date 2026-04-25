defmodule Sheaf.EmbeddingTest do
  use ExUnit.Case, async: false

  alias Sheaf.Embedding

  setup do
    Req.Test.verify_on_exit!()
  end

  test "posts raw embedContent requests for text" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1beta/models/gemini-embedding-2:embedContent"
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["secret"]

      assert %{
               "content" => %{"parts" => [%{"text" => "A paragraph."}]},
               "output_dimensionality" => 768
             } = Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      Req.Test.json(conn, %{"embedding" => %{"values" => [0.1, 0.2, 0.3]}})
    end)

    assert {:ok, %{dimensions: 3, model: "gemini-embedding-2", values: [0.1, 0.2, 0.3]}} =
             Embedding.embed_text("A paragraph.",
               api_key: "secret",
               output_dimensionality: 768,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "embeds text lists with separate requests" do
    Req.Test.expect(__MODULE__, 2, fn conn ->
      %{"content" => %{"parts" => [%{"text" => text}]}} =
        Jason.decode!(IO.iodata_to_binary(Req.Test.raw_body(conn)))

      value = if text == "First.", do: 1.0, else: 2.0
      Req.Test.json(conn, %{"embedding" => %{"values" => [value]}})
    end)

    assert {:ok, [%{values: [1.0]}, %{values: [2.0]}]} =
             Embedding.embed_texts(["First.", "Second."],
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
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
      assert {:error, :missing_gemini_api_key} = Embedding.embed_text("No key.")
    after
      if previous do
        Application.put_env(:sheaf, Embedding, previous)
      else
        Application.delete_env(:sheaf, Embedding)
      end
    end
  end
end
