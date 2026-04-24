defmodule Sheaf.Assistant.ChatTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Response}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.Chat

  test "keeps chat messages and pending state outside the LiveView process" do
    test_pid = self()

    generate_text = fn _model, context, _opts ->
      send(test_pid, {:inference_started, self(), context})

      receive do
        :finish ->
          {:ok,
           response(Context.assistant("Use this paragraph as the anchor."), finish_reason: :stop)}
      end
    end

    id = Sheaf.Id.generate()

    start_supervised!(
      {Chat,
       id: id,
       model: "test-model",
       titles: %{},
       generate_text: generate_text,
       task_supervisor: Sheaf.Assistant.TaskSupervisor}
    )

    assert %{messages: [], pending: false} = Chat.snapshot(id)

    assert :ok =
             Chat.send_user_message(id, "What should I do next?", %{
               open_document: %{title: "Draft chapter", kind: :thesis, id: "ABC123"},
               selected_id: "DEF456"
             })

    assert_receive {:inference_started, task_pid, context}
    assert user_text(context) =~ ~s|Currently open: "Draft chapter" (id ABC123, kind thesis)|
    assert user_text(context) =~ "Currently selected block: #DEF456"

    assert %{
             title: "What should I do next?",
             pending: true,
             messages: [%{role: :user, text: "What should I do next?"}]
           } = Chat.snapshot(id)

    send(task_pid, :finish)

    assert %{
             pending: false,
             messages: [
               %{role: :user, text: "What should I do next?"},
               %{role: :assistant, text: "Use this paragraph as the anchor."}
             ]
           } = wait_for_messages(id, 2)
  end

  defp wait_for_messages(id, count) do
    Enum.reduce_while(1..50, nil, fn _, _acc ->
      snapshot = Chat.snapshot(id)

      if length(snapshot.messages) >= count do
        {:halt, snapshot}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end) || flunk("timed out waiting for #{count} chat messages")
  end

  defp user_text(%Context{} = context) do
    context.messages
    |> Enum.find(&(&1.role == :user))
    |> Map.fetch!(:content)
    |> List.first()
    |> then(fn %ContentPart{text: text} -> text end)
  end

  defp response(message, opts) do
    struct!(
      Response,
      Keyword.merge(
        [
          id: "test-response-#{System.unique_integer([:positive])}",
          model: "test-model",
          context: Context.new(),
          message: message
        ],
        opts
      )
    )
  end
end
