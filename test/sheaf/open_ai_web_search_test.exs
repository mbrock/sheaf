defmodule Sheaf.OpenAI.WebSearchTest do
  use ExUnit.Case, async: true

  alias Sheaf.OpenAI.WebSearch

  test "uses the OpenAI Responses web search tool and returns sources" do
    request = fn url, opts ->
      send(self(), {:request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "output" => [
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "The DOI is 10.1/example.",
                   "annotations" => [
                     %{
                       "type" => "url_citation",
                       "url" => "https://doi.org/10.1/example"
                     }
                   ]
                 }
               ]
             }
           ]
         }
       }}
    end

    assert {:ok, result} =
             WebSearch.search("Find the DOI",
               api_key: "test-key",
               request: request
             )

    assert result.text == "The DOI is 10.1/example."

    assert result.sources == [
             %{url: "https://doi.org/10.1/example", title: nil}
           ]

    assert_received {:request, "https://api.openai.com/v1/responses", opts}
    assert opts[:json].tools == [%{type: "web_search"}]
    assert opts[:json].store == false
  end
end
