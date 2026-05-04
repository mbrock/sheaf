defmodule SheafWeb.AssistantChatComponentTest do
  use ExUnit.Case, async: true

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
end
