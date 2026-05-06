defmodule Sheaf.AssistantTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{
    Context,
    Response,
    StreamChunk,
    StreamResponse,
    Tool,
    ToolCall
  }

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamResponse.MetadataHandle
  alias Sheaf.Assistant

  test "runs a final response without tools" do
    generate_text = fn model, context, opts ->
      assert model == "test-model"
      assert opts[:tools] == []
      refute Keyword.has_key?(opts, :temperature)
      refute Keyword.has_key?(opts[:provider_options], :temperature)
      assert [%{role: :user}] = context.messages

      {:ok,
       response(Context.assistant("hello"),
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       )}
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "test-model",
         task_supervisor: Sheaf.Assistant.TaskSupervisor,
         llm_options: [temperature: 0.2, provider_options: [temperature: 1.0]],
         generate_text: generate_text}
      )

    assert {:ok, response} = Assistant.run(assistant, "hi", temperature: 0.9)
    assert Response.text(response) == "hello"

    assert %{messages: [%{role: :user}, %{role: :assistant}]} =
             Assistant.context(assistant)
  end

  test "streams response text through callbacks and returns the final response" do
    test_pid = self()

    stream_text = fn model, context, opts ->
      assert model == "openai:gpt-4"
      assert opts[:tools] == []
      assert [%{role: :user}] = context.messages
      send(test_pid, {:stream_started, self()})

      {:ok,
       stream_response(context, [
         StreamChunk.text("hel"),
         StreamChunk.text("lo")
       ])}
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "openai:gpt-4",
         task_supervisor: Sheaf.Assistant.TaskSupervisor,
         stream_text: stream_text,
         generate_text: fn _model, _context, _opts ->
           flunk("unexpected non-streaming call")
         end}
      )

    assert {:ok, response} =
             Assistant.run(assistant, "hi",
               stream: true,
               on_text_delta: fn delta -> send(test_pid, {:delta, delta}) end
             )

    assert_receive {:stream_started, _pid}
    assert_receive {:delta, "hel"}
    assert_receive {:delta, "lo"}
    assert Response.text(response) == "hello"

    assert %{messages: [%{role: :user}, %{role: :assistant}]} =
             Assistant.context(assistant)
  end

  test "executes requested tools and continues until final answer" do
    test_pid = self()

    add_tool =
      Tool.new!(
        name: "add_numbers",
        description: "Add two integers.",
        parameter_schema: [
          a: [type: :integer, required: true],
          b: [type: :integer, required: true]
        ],
        callback: fn %{a: a, b: b} ->
          send(test_pid, {:tool_executed, a, b})
          {:ok, %{"sum" => a + b}}
        end
      )

    generate_text = fn _model, context, _opts ->
      case Enum.map(context.messages, & &1.role) do
        [:user] ->
          {:ok,
           response(
             Context.assistant("I will use the tool.",
               tool_calls: [
                 ToolCall.new("call_1", "add_numbers", ~s({"a":137,"b":284}))
               ]
             ),
             finish_reason: :tool_calls
           )}

        [:user, :assistant, :tool] ->
          [tool_message] = Enum.filter(context.messages, &(&1.role == :tool))
          assert [%ContentPart{text: tool_text}] = tool_message.content
          assert tool_text =~ "421"

          {:ok,
           response(Context.assistant("137 + 284 = 421"),
             finish_reason: :stop
           )}
      end
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "test-model",
         tools: [add_tool],
         generate_text: generate_text,
         task_supervisor: Sheaf.Assistant.TaskSupervisor}
      )

    assert {:ok, response} =
             Assistant.run(assistant, "Please add 137 and 284.")

    assert Response.text(response) == "137 + 284 = 421"
    assert_receive {:tool_executed, 137, 284}

    assert %{messages: messages} = Assistant.context(assistant)

    assert Enum.map(messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "keeps streaming callbacks active after tool calls" do
    test_pid = self()

    echo_tool =
      Tool.new!(
        name: "echo_value",
        description: "Echo a value.",
        parameter_schema: [value: [type: :string, required: true]],
        callback: fn %{value: value} -> {:ok, value} end
      )

    stream_text = fn _model, context, _opts ->
      case Enum.map(context.messages, & &1.role) do
        [:user] ->
          {:ok,
           stream_response(
             context,
             [
               StreamChunk.tool_call("echo_value", %{value: "kept"}, %{
                 id: "call_1",
                 index: 0
               })
             ],
             finish_reason: :tool_calls
           )}

        [:user, :assistant, :tool] ->
          {:ok,
           stream_response(context, [
             StreamChunk.text("callback "),
             StreamChunk.text("kept")
           ])}
      end
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "openai:gpt-4",
         tools: [echo_tool],
         stream_text: stream_text,
         generate_text: fn _model, _context, _opts ->
           flunk("unexpected non-streaming call")
         end,
         task_supervisor: Sheaf.Assistant.TaskSupervisor}
      )

    assert {:ok, response} =
             Assistant.run(assistant, "echo",
               stream: true,
               on_text_delta: fn delta -> send(test_pid, {:delta, delta}) end
             )

    assert_receive {:delta, "callback "}
    assert_receive {:delta, "kept"}
    assert Response.text(response) == "callback kept"
  end

  test "returns busy while an inference task is running" do
    test_pid = self()

    generate_text = fn _model, _context, _opts ->
      send(test_pid, {:inference_started, self()})

      receive do
        :finish ->
          {:ok, response(Context.assistant("done"), finish_reason: :stop)}
      end
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "test-model",
         generate_text: generate_text,
         task_supervisor: Sheaf.Assistant.TaskSupervisor}
      )

    caller =
      Task.async(fn ->
        Assistant.run(assistant, "wait", timeout: 1_000)
      end)

    assert_receive {:inference_started, task_pid}
    assert {:error, :busy} = Assistant.run(assistant, "second")

    send(task_pid, :finish)
    assert {:ok, %Response{} = response} = Task.await(caller, 1_500)
    assert Response.text(response) == "done"
  end

  test "stops after the configured max tool rounds" do
    tool =
      Tool.new!(
        name: "echo_value",
        description: "Echo a value.",
        parameter_schema: [value: [type: :string, required: true]],
        callback: fn %{value: value} -> {:ok, value} end
      )

    generate_text = fn _model, _context, _opts ->
      {:ok,
       response(
         Context.assistant("again",
           tool_calls: [
             ToolCall.new("call_1", "echo_value", ~s({"value":"x"}))
           ]
         ),
         finish_reason: :tool_calls
       )}
    end

    assistant =
      start_supervised!(
        {Assistant,
         model: "test-model",
         tools: [tool],
         max_tool_rounds: 0,
         generate_text: generate_text,
         task_supervisor: Sheaf.Assistant.TaskSupervisor}
      )

    assert {:error, {:max_tool_rounds, %Response{}}} =
             Assistant.run(assistant, "loop")
  end

  defp response(message, opts) do
    context = Keyword.get(opts, :context, Context.new())

    struct!(
      Response,
      Keyword.merge(
        [
          id: "test-response-#{System.unique_integer([:positive])}",
          model: "test-model",
          context: context,
          message: message
        ],
        opts
      )
    )
  end

  defp stream_response(context, chunks, opts \\ []) do
    {:ok, model} = ReqLLM.model("openai:gpt-4")

    metadata = %{
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      usage: Keyword.get(opts, :usage, %{input_tokens: 1, output_tokens: 1})
    }

    {:ok, metadata_handle} = MetadataHandle.start_link(fn -> metadata end)

    %StreamResponse{
      stream: chunks,
      metadata_handle: metadata_handle,
      cancel: fn -> :ok end,
      model: model,
      context: context
    }
  end
end
