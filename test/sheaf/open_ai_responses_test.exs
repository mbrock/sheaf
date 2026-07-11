defmodule Sheaf.OpenAI.ResponsesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Message, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.OpenAI.Responses

  test "stateful requests send only the tail after the response boundary" do
    context =
      Context.new([
        Context.system(String.duplicate("stable instructions ", 100)),
        Context.user("first turn"),
        assistant("first answer", "resp_first"),
        Context.user("second turn")
      ])

    body =
      Responses.request_body("openai:gpt-5.6", context,
        prompt_cache_key: "sheaf:conversation:TEST"
      )

    assert body["previous_response_id"] == "resp_first"
    assert body["prompt_cache_key"] == "sheaf:conversation:TEST"

    assert body["prompt_cache_options"] == %{
             "mode" => "explicit",
             "ttl" => "30m"
           }

    assert [%{"role" => "user", "content" => [content]}] = body["input"]
    assert content["text"] == "second turn"
    assert content["prompt_cache_breakpoint"] == %{"mode" => "explicit"}
    refute Jason.encode!(body) =~ "first turn"
    refute Jason.encode!(body) =~ "first answer"
  end

  test "tool output after a response boundary is sent without replaying earlier output" do
    prior_call = ToolCall.new("call_old", "read", ~s({"id":"old"}))
    new_call = ToolCall.new("call_new", "read", ~s({"id":"new"}))

    context =
      Context.new([
        Context.user("start"),
        %{assistant("", "resp_tool") | tool_calls: [prior_call]},
        Context.tool_result_message("read", "call_old", "old result"),
        %Message{
          assistant("", nil)
          | tool_calls: [new_call],
            metadata: %{}
        },
        Context.tool_result_message("read", "call_new", "new result")
      ])

    body = Responses.request_body("gpt-5.6", context)

    assert body["previous_response_id"] == "resp_tool"
    encoded = Jason.encode!(body["input"])
    assert encoded =~ "old result"
    assert encoded =~ "new result"
    refute encoded =~ ~s("call_id":"call_old","name")
  end

  defp assistant(text, response_id) do
    %Message{
      role: :assistant,
      content: if(text == "", do: [], else: [ContentPart.text(text)]),
      name: nil,
      tool_call_id: nil,
      tool_calls: nil,
      metadata: if(response_id, do: %{response_id: response_id}, else: %{}),
      reasoning_details: nil
    }
  end
end
