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
end
