defmodule Sheaf.AssistantTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Response, Tool, ToolCall}
  alias ReqLLM.Message.ContentPart
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

    assert %{messages: [%{role: :user}, %{role: :assistant}]} = Assistant.context(assistant)
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
               tool_calls: [ToolCall.new("call_1", "add_numbers", ~s({"a":137,"b":284}))]
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

    assert {:ok, response} = Assistant.run(assistant, "Please add 137 and 284.")
    assert Response.text(response) == "137 + 284 = 421"
    assert_receive {:tool_executed, 137, 284}

    assert %{messages: messages} = Assistant.context(assistant)
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :assistant]
  end

  test "returns busy while an inference task is running" do
    test_pid = self()

    generate_text = fn _model, _context, _opts ->
      send(test_pid, {:inference_started, self()})

      receive do
        :finish -> {:ok, response(Context.assistant("done"), finish_reason: :stop)}
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
           tool_calls: [ToolCall.new("call_1", "echo_value", ~s({"value":"x"}))]
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

    assert {:error, {:max_tool_rounds, %Response{}}} = Assistant.run(assistant, "loop")
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
end
