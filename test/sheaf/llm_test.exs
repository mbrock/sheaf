defmodule Sheaf.LLMTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Message}
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias Sheaf.LLM

  test "builds user messages with text and file parts" do
    message =
      LLM.user_message([
        LLM.file_part("data", "paper.pdf", "application/pdf"),
        LLM.text_part("extract metadata")
      ])

    assert %Message{} = message
    assert [file_part, text_part] = message.content
    assert file_part.type == :file
    assert file_part.data == "data"
    assert file_part.filename == "paper.pdf"
    assert file_part.media_type == "application/pdf"
    assert text_part.type == :text
    assert text_part.text == "extract metadata"
  end

  test "removes unsigned cross-provider thinking before an Anthropic request" do
    gpt_message = %Message{
      role: :assistant,
      content: [
        ContentPart.text("Visible answer."),
        ContentPart.thinking("GPT reasoning summary")
      ],
      tool_calls: [],
      reasoning_details: [
        %ReasoningDetails{provider: :openai, text: nil, index: 0}
      ]
    }

    anthropic_message = %Message{
      role: :assistant,
      content: [
        ContentPart.text("Earlier Claude answer."),
        ContentPart.thinking("Claude reasoning summary")
      ],
      reasoning_details: [
        %ReasoningDetails{
          provider: :anthropic,
          text: "Claude reasoning summary",
          signature: "signed",
          index: 0
        }
      ]
    }

    context = Context.new([gpt_message, anthropic_message])

    assert %{messages: [sanitized_gpt, sanitized_anthropic]} =
             LLM.context_for_model("anthropic:claude-opus-4-7", context)

    assert Enum.map(sanitized_gpt.content, & &1.type) == [:text]
    assert sanitized_gpt.reasoning_details == nil
    assert Enum.map(sanitized_anthropic.content, & &1.type) == [:text]

    assert [%ReasoningDetails{signature: "signed"}] =
             sanitized_anthropic.reasoning_details

    assert LLM.context_for_model("openai:gpt-5.6-sol", context) == context
  end

  test "generates objects with default request options" do
    test_pid = self()

    generate_object = fn model, message, schema, opts ->
      send(test_pid, {:request, model, message, schema, opts})

      {:ok,
       %{
         object: %{"title" => "A Paper"},
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end

    message = LLM.user_message([LLM.text_part("extract metadata")])
    schema = [title: [type: :string, required: true]]

    assert {:ok, result} =
             LLM.generate_object(message, schema,
               generate_object: generate_object
             )

    assert result.object == %{"title" => "A Paper"}
    assert result.model == LLM.default_model()
    assert result.usage == %{input_tokens: 10, output_tokens: 5}

    assert_receive {:request, model, ^message, ^schema, opts}
    assert model == LLM.default_model()
    refute Keyword.has_key?(opts, :temperature)
    assert opts[:max_tokens] == 65_536
    assert opts[:receive_timeout] == 300_000

    assert opts[:provider_options][:thinking] == %{
             type: "adaptive",
             display: "omitted"
           }
  end

  test "resolves assistant provider choices to model specs" do
    assert [
             %{
               provider: "claude-opus-4-6",
               label: "Claude Opus 4.6",
               model: "anthropic:claude-opus-4-6"
             },
             %{
               provider: "claude-opus-4-8",
               label: "Claude Opus 4.8",
               model: "anthropic:claude-opus-4-8"
             },
             %{
               provider: "claude-sonnet-5",
               label: "Claude Sonnet 5",
               model: "anthropic:claude-sonnet-5"
             },
             %{
               provider: "claude-fable-5",
               label: "Claude Fable 5",
               model: "anthropic:claude-fable-5"
             },
             %{
               provider: "gpt-sol",
               label: "GPT Sol",
               model: "openai:gpt-5.6-sol"
             },
             %{
               provider: "gpt-terra",
               label: "GPT Terra",
               model: "openai:gpt-5.6-terra"
             },
             %{
               provider: "gpt-luna",
               label: "GPT Luna",
               model: "openai:gpt-5.6-luna"
             }
           ] = LLM.assistant_model_options()

    assert LLM.default_assistant_provider() == "claude-opus-4-8"

    assert LLM.assistant_model_for_provider("claude-opus-4-8") ==
             "anthropic:claude-opus-4-8"

    assert LLM.assistant_model_for_provider("gpt-sol") ==
             "openai:gpt-5.6-sol"

    assert LLM.assistant_model_for_provider("gpt-terra") ==
             "openai:gpt-5.6-terra"

    assert LLM.assistant_model_for_provider("gpt-luna") ==
             "openai:gpt-5.6-luna"

    assert LLM.assistant_provider_for_model("openai:gpt-5.6-sol") ==
             "gpt-sol"

    assert LLM.assistant_reasoning_effort_options("gpt-sol") ==
             ~w(none low medium high xhigh max)

    assert LLM.assistant_reasoning_effort_options("claude-opus-4-6") ==
             ~w(low medium high max)

    assert LLM.assistant_reasoning_effort_options("claude-opus-4-8") ==
             ~w(low medium high xhigh max)

    assert LLM.assistant_reasoning_effort_options("claude-sonnet-5") ==
             ~w(low medium high xhigh max)

    assert LLM.assistant_reasoning_effort_options("claude-fable-5") ==
             ~w(low medium high xhigh max)

    assert LLM.assistant_provider_for_model("anthropic:claude-opus-4-8") ==
             "claude-opus-4-8"

    for model <- ~w(
          anthropic:claude-opus-4-6
          anthropic:claude-opus-4-8
          anthropic:claude-sonnet-5
          anthropic:claude-fable-5
        ) do
      assert {:ok, _model} = ReqLLM.model(model)
    end
  end

  test "sets GPT assistant reasoning effort by conversation mode" do
    assert LLM.assistant_llm_options("gpt", "quick") == [
             reasoning_effort: :medium,
             provider_options: [reasoning_summary: :auto]
           ]

    assert LLM.assistant_llm_options("openai:gpt-5.6", :chat) == [
             reasoning_effort: :medium,
             provider_options: [reasoning_summary: :auto]
           ]

    assert LLM.assistant_llm_options("gpt", "research") == [
             reasoning_effort: :high,
             provider_options: [reasoning_summary: :auto]
           ]

    assert LLM.assistant_llm_options("anthropic:claude-opus-4-8", "research") ==
             []
  end

  test "enables adaptive thinking and maps Claude effort into output configuration" do
    options =
      LLM.text_request_options(
        model: "anthropic:claude-opus-4-8",
        reasoning_effort: :xhigh
      )

    assert options[:provider_options][:thinking] == %{
             type: "adaptive",
             display: "omitted"
           }

    {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

    {translated, []} =
      ReqLLM.Providers.Anthropic.translate_options(:chat, model, options)

    assert translated[:thinking] == %{type: "adaptive", display: "summarized"}
    assert translated[:output_config] == %{effort: "max"}
  end

  test "requests and decodes streamed OpenAI reasoning summaries" do
    options =
      LLM.text_request_options(
        model: "openai:gpt-5.6",
        llm_options: LLM.assistant_llm_options("gpt", :research)
      )

    body =
      ResponsesAPI.build_request_body(
        Context.new(),
        "gpt-5.6",
        options,
        %{options: options}
      )

    assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    refute Map.has_key?(body, "parallel_tool_calls")

    {:ok, model} = ReqLLM.model("openai:gpt-5.6")

    assert [%ReqLLM.StreamChunk{type: :thinking, text: "Checking sources."}] =
             ResponsesAPI.decode_stream_event(
               %{
                 data: %{
                   "type" => "response.reasoning_summary_text.delta",
                   "delta" => "Checking sources."
                 }
               },
               model
             )

    {:ok, inline_model} = ReqLLM.model(%{provider: :openai, id: "gpt-5.6"})

    assert {:ok, %Finch.Request{}} =
             ResponsesAPI.attach_stream(
               inline_model,
               Context.new(),
               options,
               ReqLLM.Finch
             )
  end

  test "merges provider options and request overrides" do
    opts =
      LLM.request_options(
        temperature: 0.2,
        max_tokens: 4_096,
        reasoning_effort: :medium,
        thinking: %{"type" => "adaptive"},
        receive_timeout: 5_000,
        provider_options: [temperature: 1.0, custom: true],
        llm_options: [
          temperature: 0.9,
          provider_options: [temperature: 0.1, other: "value"],
          retries: false
        ]
      )

    refute Keyword.has_key?(opts, :temperature)
    assert opts[:max_tokens] == 4_096
    assert opts[:reasoning_effort] == :medium
    assert opts[:receive_timeout] == 5_000
    assert opts[:retries] == false
    assert opts[:provider_options][:thinking] == %{"type" => "adaptive"}
    assert opts[:provider_options][:custom] == true
    assert opts[:provider_options][:other] == "value"
    refute Keyword.has_key?(opts[:provider_options], :temperature)
  end

  test "can omit default max tokens and thinking options" do
    opts = LLM.request_options(max_tokens: nil, thinking: false)

    refute Keyword.has_key?(opts, :max_tokens)
    refute Keyword.has_key?(opts[:provider_options], :thinking)
  end

  test "text request options preserve tools and strip temperature" do
    tool = %{name: "add_numbers"}

    opts =
      LLM.text_request_options(
        tools: [tool],
        temperature: 0.2,
        provider_options: [temperature: 1.0],
        llm_options: [temperature: 0.9]
      )

    assert opts[:tools] == [tool]
    refute Keyword.has_key?(opts, :temperature)
    refute Keyword.has_key?(opts[:provider_options], :temperature)
  end

  test "text request options enable Anthropic context caching by default" do
    opts = LLM.text_request_options(model: "anthropic:claude-sonnet-4-6")

    assert opts[:provider_options][:anthropic_prompt_cache] == true
    assert opts[:provider_options][:anthropic_cache_messages] == true
  end

  test "text request options preserve explicit Anthropic context cache overrides" do
    opts =
      LLM.text_request_options(
        model: "anthropic:claude-sonnet-4-6",
        provider_options: [
          anthropic_prompt_cache: false,
          anthropic_cache_messages: -2
        ]
      )

    assert opts[:provider_options][:anthropic_prompt_cache] == false
    assert opts[:provider_options][:anthropic_cache_messages] == -2
  end

  test "text request options only apply Opus adaptive thinking to Opus" do
    sonnet_opts =
      LLM.text_request_options(model: "anthropic:claude-sonnet-4-6")

    opus_opts = LLM.text_request_options(model: "anthropic:claude-opus-4-7")

    refute Keyword.has_key?(sonnet_opts[:provider_options], :thinking)
    assert opus_opts[:provider_options][:thinking] == LLM.default_thinking()
  end
end
