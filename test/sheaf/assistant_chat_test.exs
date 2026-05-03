defmodule Sheaf.Assistant.ChatTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Response, Tool}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.Chat
  alias Sheaf.Spreadsheet.Metadata
  alias Sheaf.XLSXFixture

  test "keeps chat messages and pending state outside the LiveView process" do
    test_pid = self()

    generate_text = fn _model, context, opts ->
      send(test_pid, {:inference_started, self(), context})
      refute Enum.any?(opts[:tools], &(&1.name == "write_note"))

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
       workspace_instructions: "This workspace is for a test thesis about public procurement.",
       activity_writer: nil,
       generate_text: generate_text,
       task_supervisor: Sheaf.Assistant.TaskSupervisor}
    )

    assert %{messages: [], pending: false} = Chat.snapshot(id)

    assert :ok =
             Chat.send_user_message(id, "What should I do next?", %{
               open_document: %{title: "Draft chapter", kind: :thesis, id: "ABC123"},
               working_document: %{title: "Draft chapter", kind: :thesis, id: "ABC123"},
               selected_id: "DEF456",
               selected_block_context: """
               The user has selected paragraph #DEF456:
                 Text:
                   Selected paragraph text.
               """
             })

    assert_receive {:inference_started, task_pid, context}
    assert user_text(context) =~ "The user is working on:"
    assert user_text(context) =~ "Draft chapter (#ABC123, thesis)"
    assert user_text(context) =~ "The user has this document open."
    assert user_text(context) =~ "The user has selected paragraph #DEF456:"
    assert user_text(context) =~ "Selected paragraph text."
    refute user_text(context) =~ "Workspace:"
    refute user_text(context) =~ "Document: #ABC123 Draft chapter"
    refute system_text(context) =~ "write_note"
    assert system_text(context) =~ "Do not end by offering optional follow-up help"
    assert system_text(context) =~ "test thesis about public procurement"
    refute system_text(context) =~ "Ieva"
    refute system_text(context) =~ "brīvbode"

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

  test "research-mode conversations expose their kind and get research prompt guidance" do
    test_pid = self()

    generate_text = fn _model, context, opts ->
      send(test_pid, {:research_inference_started, self(), context})
      assert Enum.any?(opts[:tools], &(&1.name == "write_note"))

      receive do
        :finish ->
          {:ok, response(Context.assistant("I wrote the durable notes."), finish_reason: :stop)}
      end
    end

    id = Sheaf.Id.generate()

    start_supervised!(
      {Chat,
       id: id,
       kind: :research,
       model: "test-model",
       titles: %{},
       workspace_instructions: "This workspace is for a research-mode test thesis.",
       activity_writer: nil,
       generate_text: generate_text,
       task_supervisor: Sheaf.Assistant.TaskSupervisor}
    )

    assert %{title: "Assistant conversation", kind: :research, pending: false} = Chat.snapshot(id)

    assert :ok = Chat.send_user_message(id, "Read the circular economy papers.")

    assert_receive {:research_inference_started, task_pid, context}
    assert system_text(context) =~ "Research mode:"
    assert system_text(context) =~ "write durable"

    assert %{title: "Read the circular economy papers.", kind: :research, pending: true} =
             Chat.snapshot(id)

    send(task_pid, :finish)

    assert %{
             kind: :research,
             pending: false,
             messages: [
               %{role: :user, text: "Read the circular economy papers."},
               %{role: :assistant, text: "I wrote the durable notes."}
             ]
           } = wait_for_messages(id, 2)
  end

  test "can switch the routed model before the next turn" do
    test_pid = self()

    generate_text = fn model, context, opts ->
      send(test_pid, {:inference_started, model, context, opts})
      {:ok, response(Context.assistant("Routed."), finish_reason: :stop)}
    end

    id = Sheaf.Id.generate()

    start_supervised!(
      {Chat,
       id: id,
       model: "anthropic:claude-opus-4-7",
       titles: %{},
       workspace_instructions: "Testing model routing.",
       activity_writer: nil,
       generate_text: generate_text,
       task_supervisor: Sheaf.Assistant.TaskSupervisor}
    )

    assert %{model: "anthropic:claude-opus-4-7"} = Chat.snapshot(id)
    assert :ok = Chat.put_model(id, "openai:gpt-5.5")
    assert :ok = Chat.put_llm_options(id, reasoning_effort: :high)
    assert %{model: "openai:gpt-5.5", llm_options: [reasoning_effort: :high]} = Chat.snapshot(id)

    assert :ok = Chat.send_user_message(id, "Use GPT for this.")
    assert_receive {:inference_started, "openai:gpt-5.5", _context, opts}
    assert opts[:reasoning_effort] == :high

    assert %{
             pending: false,
             messages: [
               %{role: :user, text: "Use GPT for this."},
               %{role: :assistant, text: "Routed."}
             ]
           } = wait_for_messages(id, 2)
  end

  @tag :tmp_dir
  test "chat sessions expose per-chat DuckDB spreadsheet tools", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")

    XLSXFixture.write_xlsx!(xlsx_path, [
      ["buyer_type", "amount"],
      ["agency", "3"]
    ])

    test_pid = self()
    blob_root = Path.join(tmp_dir, "blobs")

    assert {:ok, _result} =
             Metadata.import_file(xlsx_path,
               directory: tmp_dir,
               blob_root: blob_root,
               persist: fn graph ->
                 send(test_pid, {:spreadsheet_workspace_graph, graph})
                 :ok
               end
             )

    assert_receive {:spreadsheet_workspace_graph, spreadsheet_workspace_graph}

    generate_text = fn _model, _context, opts ->
      tools = Keyword.fetch!(opts, :tools)
      list_tool = Enum.find(tools, &(&1.name == "list_spreadsheets"))
      query_tool = Enum.find(tools, &(&1.name == "query_spreadsheets"))

      assert %Tool{} = list_tool
      assert %Tool{} = query_tool

      {:ok, list_result} = Tool.execute(list_tool, %{})
      [%{sheets: [%{table_name: table}]}] = list_result.metadata.sheaf_result.spreadsheets

      {:ok, query_result} =
        Tool.execute(query_tool, %{
          "sql" => """
          CREATE TEMP VIEW agency_rows AS
          SELECT buyer_type, amount FROM "#{table}" WHERE buyer_type = 'agency';

          SELECT * FROM agency_rows;
          """
        })

      send(test_pid, {:spreadsheet_rows, query_result.metadata.sheaf_result.rows})
      {:ok, response(Context.assistant("Spreadsheet checked."), finish_reason: :stop)}
    end

    id = Sheaf.Id.generate()

    start_supervised!(
      {Chat,
       id: id,
       model: "test-model",
       titles: %{},
       workspace_instructions: "Testing spreadsheet tools.",
       spreadsheet_directory: tmp_dir,
       spreadsheet_workspace_graph: spreadsheet_workspace_graph,
       spreadsheet_blob_root: blob_root,
       activity_writer: nil,
       generate_text: generate_text,
       task_supervisor: Sheaf.Assistant.TaskSupervisor}
    )

    assert :ok = Chat.send_user_message(id, "Check the spreadsheet.")
    assert_receive {:spreadsheet_rows, [%{"amount" => "3", "buyer_type" => "agency"}]}

    assert %{pending: false, messages: messages} = wait_for_messages(id, 4)
    assert List.first(messages) == %{role: :user, text: "Check the spreadsheet."}
    assert List.last(messages) == %{role: :assistant, text: "Spreadsheet checked."}
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
    message_text(context, :user)
  end

  defp system_text(%Context{} = context) do
    message_text(context, :system)
  end

  defp message_text(%Context{} = context, role) do
    context.messages
    |> Enum.find(&(&1.role == role))
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
