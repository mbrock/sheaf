defmodule Sheaf.Assistant.StreamBufferTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.StreamBuffer

  test "holds character fragments until an English sentence boundary" do
    buffer = StreamBuffer.new()

    assert {[], buffer} = StreamBuffer.push(buffer, "This is incom")

    assert {["This is incomplete. "], buffer} =
             StreamBuffer.push(buffer, "plete. Next")

    assert {"Next", _buffer} = StreamBuffer.flush(buffer)
  end

  test "does not split common abbreviations as sentences" do
    buffer = StreamBuffer.new()

    assert {[], buffer} = StreamBuffer.push(buffer, "See Fig. ")

    assert {["See Fig. 2 for context. "], _buffer} =
             StreamBuffer.push(buffer, "2 for context. Then")
  end

  test "keeps unclosed inline markdown together" do
    buffer = StreamBuffer.new()

    assert {[], buffer} = StreamBuffer.push(buffer, "This is **important.")

    assert {["This is **important.** "], _buffer} =
             StreamBuffer.push(buffer, "** Next")
  end

  test "keeps unclosed fenced code together" do
    buffer = StreamBuffer.new()

    assert {[], buffer} =
             StreamBuffer.push(buffer, "```elixir\nIO.puts(\"hi\")\n")

    assert {["```elixir\nIO.puts(\"hi\")\n```\n"], _buffer} =
             StreamBuffer.push(buffer, "```\nAfter")
  end

  test "flushes complete markdown lines without waiting for sentence punctuation" do
    buffer = StreamBuffer.new()

    assert {["- first item\n"], buffer} =
             StreamBuffer.push(buffer, "- first item\n- second")

    assert {"- second", _buffer} = StreamBuffer.flush(buffer)
  end
end
