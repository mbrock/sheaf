defmodule Sheaf.LLMTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
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

    assert {:ok, result} = LLM.generate_object(message, schema, generate_object: generate_object)
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
    sonnet_opts = LLM.text_request_options(model: "anthropic:claude-sonnet-4-6")
    opus_opts = LLM.text_request_options(model: "anthropic:claude-opus-4-7")

    refute Keyword.has_key?(sonnet_opts[:provider_options], :thinking)
    assert opus_opts[:provider_options][:thinking] == LLM.default_thinking()
  end
end
