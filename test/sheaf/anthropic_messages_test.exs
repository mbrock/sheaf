defmodule Sheaf.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Message, ToolCall}
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}
  alias Sheaf.Anthropic.Messages

  test "builds a cached Anthropic request and replays signed thinking" do
    context =
      Context.new([
        Context.system("Stable system instructions"),
        Context.user("First question"),
        %Message{
          role: :assistant,
          content: [ContentPart.text("First answer")],
          name: nil,
          tool_call_id: nil,
          tool_calls: nil,
          metadata: %{},
          reasoning_details: [
            %ReasoningDetails{
              text: "Private reasoning",
              signature: "signed-thinking",
              encrypted?: true,
              provider: :anthropic,
              format: "anthropic-thinking-v1",
              index: 0,
              provider_data: %{}
            }
          ]
        },
        Context.user("Second question")
      ])

    body =
      Messages.request_body("anthropic:claude-opus-4-8", context,
        reasoning_effort: :high,
        provider_options: [thinking: %{type: "adaptive"}]
      )

    assert body["model"] == "claude-opus-4-8"
    assert body["max_tokens"] == 128_000
    assert body["thinking"] == %{"type" => "adaptive"}
    assert body["output_config"] == %{"effort" => "high"}
    assert [%{"cache_control" => %{"type" => "ephemeral"}}] = body["system"]

    assert Enum.any?(body["messages"], fn message ->
             Enum.any?(message["content"], fn
               %{
                 "type" => "thinking",
                 "signature" => "signed-thinking"
               } ->
                 true

               _ ->
                 false
             end)
           end)

    latest = List.last(body["messages"])
    assert latest["role"] == "user"

    assert List.last(latest["content"])["cache_control"] == %{
             "type" => "ephemeral"
           }
  end

  test "encodes assistant tool calls and user tool results" do
    call = ToolCall.new("tool_1", "lookup", ~s({"id":"A"}))

    assistant = %Message{
      role: :assistant,
      content: [],
      name: nil,
      tool_call_id: nil,
      tool_calls: [call],
      metadata: %{},
      reasoning_details: nil
    }

    context =
      Context.new([
        Context.user("Look it up"),
        assistant,
        Context.tool_result_message("lookup", "tool_1", %{answer: 42})
      ])

    body = Messages.request_body("claude-opus-4-8", context)
    encoded = Jason.encode!(body["messages"])

    assert encoded =~ ~s("type":"tool_use")
    assert encoded =~ ~s("type":"tool_result")

    assert %{"content" => [%{"content" => result}]} =
             List.last(body["messages"])

    assert Jason.decode!(result) == %{"answer" => 42}
  end

  test "allows Anthropic prompt caching to be disabled" do
    context =
      Context.new([Context.system("system"), Context.user("question")])

    body =
      Messages.request_body("claude-opus-4-8", context,
        provider_options: [
          anthropic_prompt_cache: false,
          anthropic_cache_messages: false
        ]
      )

    refute Jason.encode!(body) =~ "cache_control"
  end
end
