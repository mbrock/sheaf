defmodule SheafWeb.AssistantChatComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

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
                   "model_provider" => "claude"
                 }
               },
               socket
             )

    assert socket.assigns.mode == "research"
    assert socket.assigns.model_provider == "claude"
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
    assert socket.assigns.model_provider == "gpt"
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

  test "existing conversations keep their original mode and model options" do
    {:ok, socket} = AssistantChatComponent.mount(%Phoenix.LiveView.Socket{})

    socket =
      socket
      |> Phoenix.Component.assign(:selected_chat_id, "CHAT01")
      |> Phoenix.Component.assign(:mode, "quick")
      |> Phoenix.Component.assign(:model_provider, "claude")
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
    assert socket.assigns.model_provider == "claude"
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
        form: Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"}, as: :chat),
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
          messages: [%{role: :assistant, text: "A complete sentence. ", streaming?: true}],
          pending: true,
          status_line: "Writing",
          titles: %{}
        },
        selected_chat_id: "CHAT01",
        form: Phoenix.Component.to_form(%{"message" => "", "mode" => "quick"}, as: :chat),
        mode: "quick",
        model_provider: "claude",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(phx-hook="AssistantTypeWriter")
    assert html =~ ~s(data-typewriter-streaming)
    assert html =~ "A complete sentence."
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
            %{"message" => "", "mode" => "quick", "model_provider" => "claude"},
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
