defmodule Sheaf.BlockRefsTest do
  use ExUnit.Case, async: true

  alias Sheaf.BlockRefs

  test "links hash and bare block ids without rewriting existing block links" do
    text = "See ABC234, #DEF456, and [SJ3K7R], but not [#GHK789](/b/GHK789) again."

    assert BlockRefs.linkify_markdown(text) ==
             "See [#ABC234](/b/ABC234), [#DEF456](/b/DEF456), and [#SJ3K7R](/b/SJ3K7R), but not [#GHK789](/b/GHK789) again."
  end

  test "extracts ids from bare text and existing links" do
    text = "See ABC234, #DEF456, [SJ3K7R], and [#GHK789](/b/GHK789)."

    assert BlockRefs.ids_from_text(text) == ["ABC234", "DEF456", "SJ3K7R", "GHK789"]
  end
end
