defmodule Sheaf.Assistant.ChatsTest do
  use ExUnit.Case, async: false

  alias Sheaf.Assistant.{Chat, Chats}

  test "unlisted chats start a chat process without entering the global chat list" do
    id = Sheaf.Id.generate()

    assert %{id: ^id} =
             Chats.create(
               id: id,
               listed?: false,
               model: "test-model",
               titles: %{},
               generate_text: fn _model, _context, _opts ->
                 flunk("unexpected inference")
               end
             )

    assert Chat.exists?(id)
    refute Enum.any?(Chats.list(), &(&1.id == id))
  end
end
