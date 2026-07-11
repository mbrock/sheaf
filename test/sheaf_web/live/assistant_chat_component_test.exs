defmodule SheafWeb.AssistantChatComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Sheaf.Assistant.ToolResults
  alias Sheaf.Assistant.ToolResults.PresentedSpreadsheetQueryResult
  alias SheafWeb.AssistantChatComponent

  test "option changes preserve the drafted message" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Keep this draft.",
                   "mode" => "research",
                   "model_provider" => "claude-opus-4-8"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "research"
    assert socket.assigns.model_provider == "claude-opus-4-8"
    assert socket.assigns.form.params["message"] == "Keep this draft."

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Keep this draft.",
                   "mode" => "research",
                   "model_provider" => "gpt"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "research"
    assert socket.assigns.model_provider == "gpt-sol"
    assert socket.assigns.form.params["message"] == "Keep this draft."
  end

  test "option changes accept edit mode" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Move this paragraph.",
                   "mode" => "edit",
                   "model_provider" => "claude"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "edit"
    assert socket.assigns.form.params["message"] == "Move this paragraph."
  end

  test "model and documented reasoning effort can be selected independently" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Compare this draft.",
                   "mode" => "research",
                   "model_provider" => "gpt-terra",
                   "reasoning_effort" => "max"
                 }
               },
               socket
             )

    assert socket.assigns.model_provider == "gpt-terra"
    assert socket.assigns.model == "openai:gpt-5.6-terra"
    assert socket.assigns.reasoning_effort == "max"
    assert socket.assigns.form.params["reasoning_effort"] == "max"
    assert socket.assigns.form.params["message"] == "Compare this draft."

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Compare this draft.",
                   "mode" => "research",
                   "model_provider" => "claude-opus-4-6",
                   "reasoning_effort" => "xhigh"
                 }
               },
               socket
             )

    assert socket.assigns.model == "anthropic:claude-opus-4-6"
    assert socket.assigns.reasoning_effort == "high"
  end

  test "import mode preserves the selected Claude model and reasoning effort" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Import this PDF.",
                   "mode" => "import",
                   "model_provider" => "claude-sonnet-5",
                   "reasoning_effort" => "xhigh"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "import"
    assert socket.assigns.model_provider == "claude-sonnet-5"
    assert socket.assigns.model == "anthropic:claude-sonnet-5"
    assert socket.assigns.reasoning_effort == "xhigh"
  end

  test "upload updates preserve a draft's model and reasoning effort" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Keep this import draft.",
                   "mode" => "import",
                   "model_provider" => "claude-fable-5",
                   "reasoning_effort" => "xhigh"
                 }
               },
               socket
             )

    assert {:ok, socket} =
             AssistantChatComponent.update(
               %{import_uploads: [%{id: "PDF01"}]},
               socket
             )

    assert socket.assigns.mode == "import"
    assert socket.assigns.model_provider == "claude-fable-5"
    assert socket.assigns.reasoning_effort == "xhigh"
    assert socket.assigns.form.params["message"] == "Keep this import draft."
  end

  test "existing conversations keep their original mode and model options" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    socket =
      socket
      |> Phoenix.Component.assign(:selected_chat_id, "CHAT01")
      |> Phoenix.Component.assign(:mode, "quick")
      |> Phoenix.Component.assign(:model_provider, "claude-opus-4-8")
      |> Phoenix.Component.assign(:model, Sheaf.LLM.default_model())

    assert {:noreply, socket} =
             AssistantChatComponent.handle_event(
               "set_options",
               %{
                 "chat" => %{
                   "message" => "Reply draft.",
                   "mode" => "research",
                   "model_provider" => "gpt"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "quick"
    assert socket.assigns.model_provider == "claude-opus-4-8"
    assert socket.assigns.model == Sheaf.LLM.default_model()
    assert socket.assigns.form.params["message"] == "Reply draft."
  end

  test "existing full-page conversations render a compact reply composer" do
    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{messages: [], pending: false, titles: %{}},
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(placeholder="Reply to assistant")
    assert html =~ ~s(aria-label="Send")
    refute html =~ ~s(name="chat[mode]")
    refute html =~ ~s(name="chat[model_provider]")
  end

  test "streaming assistant messages opt into typewriter reveal" do
    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{
          messages: [
            %{
              role: :assistant,
              text: "A complete sentence. ",
              streaming?: true
            }
          ],
          pending: true,
          status_line: "Writing",
          elapsed_label: "12s",
          activity_detail:
            "18 reasoning characters received · last activity 2s ago",
          thinking_text:
            "I checked the imported outline and found a likely title.",
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(phx-hook="AssistantTypeWriter")
    assert html =~ ~s(data-typewriter-streaming)
    assert html =~ "A complete sentence."
    assert html =~ "12s"
    assert html =~ "18 reasoning characters received"
    assert html =~ "I checked the imported outline and found a likely title."
  end

  test "tool call groups render as compact activity rows" do
    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{
          messages: [
            %{
              role: :tool,
              tool: "list_documents",
              status: :ok,
              summary: "8 documents",
              input: %{}
            },
            %{
              role: :tool,
              tool: "search_text",
              status: :pending,
              input: %{"query" => "circular work"}
            },
            %{
              role: :tool,
              tool: "web_search",
              status: :ok,
              summary: "1 source",
              input: %{"query" => "Mountain Trail Formation Gilks Hague"},
              result: %ToolResults.WebSearch{
                query: "Mountain Trail Formation Gilks Hague",
                text: "The paper was published in 2008.",
                sources: [
                  %{
                    title: "Publisher record",
                    url: "https://example.org/paper"
                  }
                ]
              }
            }
          ],
          pending: false,
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(aria-label="Assistant tool activity")
    assert html =~ "Listing documents"
    assert html =~ "8 documents"
    assert html =~ "Searching for"
    assert html =~ "working"
    assert html =~ "hero-document-duplicate"
    assert html =~ "hero-magnifying-glass"
    assert html =~ "Searching the web"
    assert html =~ "Mountain Trail Formation Gilks Hague"
    assert html =~ "The paper was published in 2008."
    assert html =~ "Publisher record"
    assert html =~ "https://example.org/paper"
    refute html =~ ~s(class="hidden text-sm)
  end

  test "search result tool panes tolerate hydrated legacy nil coding" do
    result = %ToolResults.SearchResults{
      exact_results: [
        %ToolResults.SearchHit{
          document_id: "DOC123",
          document_title: "A paper",
          document_status: "draft",
          block_id: "BLK123",
          kind: :paragraph,
          text: "Plastic appears exactly here.",
          match: :exact,
          score: 0.95,
          coding: "nil",
          context: [%{"title" => "Literature review"}]
        }
      ]
    }

    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{
          messages: [
            %{
              role: :tool,
              tool: "search_text",
              status: :ok,
              result: result,
              input: %{"query" => "Plastic"}
            }
          ],
          pending: false,
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ "Exact matches"
    assert html =~ "#BLK123"
    assert html =~ "A paper"
    assert html =~ "Literature review"
    assert html =~ "<mark"
  end

  test "block result panes tolerate hydrated legacy nil source" do
    result = %ToolResults.Blocks{
      blocks: [
        %ToolResults.Block{
          document_id: "DOC123",
          id: "BLK123",
          type: :paragraph,
          source: "nil",
          text: "A paragraph returned from a legacy snapshot."
        }
      ]
    }

    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{
          messages: [
            %{
              role: :tool,
              tool: "read",
              status: :ok,
              result: result,
              input: %{"blocks" => ["BLK123"]}
            }
          ],
          pending: false,
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ "#BLK123"
    assert html =~ "legacy snapshot"
  end

  test "presented spreadsheet query results render as data tables" do
    result = %PresentedSpreadsheetQueryResult{
      id: "QRY123",
      iri: "https://sheaf.less.rest/QRY123",
      title: "Tender counts",
      description: "Grouped by bid_level and buyer type.",
      columns: ["buyer_type", "tenders"],
      rows: [%{"buyer_type" => "agency", "tenders" => 12}],
      row_count: 42,
      offset: 5,
      limit: 25,
      column_specs: [
        %{name: "buyer_type", label: "Buyer type", type: "text", unit: nil}
      ]
    }

    html =
      render_component(&AssistantChatComponent.render/1,
        id: "assistant-conversation-CHAT01",
        variant: :full_page,
        chat: %{
          messages: [
            %{
              role: :tool,
              tool: "present_spreadsheet_query_result",
              status: :ok,
              summary: "Tender counts; 1 row",
              result: result,
              input: %{}
            }
          ],
          pending: false,
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form:
          Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"},
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ "Tender counts"
    assert html =~ "Grouped by"
    assert html =~ "bid level"
    assert html =~ ~s(class="font-mono)
    assert html =~ ~s(phx-hook="DataTable")
    assert html =~ "Buyer type"
    assert html =~ "agency"
    refute html =~ "Showing 1 row from offset 5 of 42"
    refute html =~ "Spreadsheet query result"
    assert html =~ ~s(href="/QRY123")
  end

  test "document sidebar composer shows selected block context without chat history chrome" do
    html =
      render_component(&AssistantChatComponent.render/1,
        id: "document-block-assistant-DOC01",
        variant: :document_sidebar,
        chat: %{messages: [], pending: false, titles: %{}},
        chats: [],
        composer_only?: false,
        selected_chat_id: nil,
        selected_id: "PL9BXR",
        form:
          Phoenix.Component.to_form(
            %{
              "message" => "",
              "mode" => "quick",
              "model_provider" => "claude"
            },
            as: :chat
          ),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ "#PL9BXR"
    assert html =~ ~s(placeholder="Ask a quick question")
    refute html =~ "Current"
    refute html =~ "New conversation"
  end
end
