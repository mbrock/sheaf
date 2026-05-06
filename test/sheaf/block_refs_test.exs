defmodule Sheaf.BlockRefsTest do
  use ExUnit.Case, async: true

  alias Sheaf.BlockRefs

  test "links explicit block ids without rewriting existing block links" do
    text =
      "See ABC234, #DEF456, and [SJ3K7R], but not [#GHK789](/b/GHK789) again."

    assert BlockRefs.linkify_markdown(text) ==
             "See ABC234, [#DEF456](/b/DEF456), and [#SJ3K7R](/b/SJ3K7R), but not [#GHK789](/b/GHK789) again."
  end

  test "only links ids accepted by the predicate" do
    text = "Use #ABC234, #DEF456, and query result #PK9ACK."

    assert BlockRefs.linkify_markdown(text, exists?: &(&1 == "DEF456")) ==
             "Use #ABC234, [#DEF456](/b/DEF456), and query result #PK9ACK."
  end

  test "can link ids to non-block resource paths" do
    text = "Read result #PK9ACK and block #DEF456."

    assert BlockRefs.linkify_markdown(text,
             url_for: fn
               "PK9ACK" -> "/PK9ACK"
               "DEF456" -> "/b/DEF456"
               _id -> nil
             end
           ) ==
             "Read result [#PK9ACK](/PK9ACK) and block [#DEF456](/b/DEF456)."
  end

  test "accepts looser hash refs and normalizes spaces before punctuation" do
    text = "Compare (#foo , #BAR and #LONGER12345 !)"

    assert BlockRefs.linkify_markdown(text,
             url_for: fn
               "FOO" -> "/b/FOO"
               "BAR" -> "/b/BAR"
               "LONGER12345" -> "/b/LONGER12345"
               _id -> nil
             end
           ) ==
             "Compare ([#FOO](/b/FOO), [#BAR](/b/BAR) and [#LONGER12345](/b/LONGER12345)!)"
  end

  test "turns resource-only inline code spans into normal links" do
    text = "Read result `#PK9ACK`, but keep `SELECT #PK9ACK` as code."

    assert BlockRefs.linkify_markdown(text,
             url_for: fn
               "PK9ACK" -> "/PK9ACK"
               _id -> nil
             end
           ) ==
             "Read result [#PK9ACK](/PK9ACK), but keep `SELECT #PK9ACK` as code."
  end

  test "does not normalize spaces before punctuation inside inline code" do
    text = "Read #ABC123 , but keep `#ABC123 , #DEF456` as code."

    assert BlockRefs.linkify_markdown(text,
             url_for: fn
               "ABC123" -> "/b/ABC123"
               _id -> nil
             end
           ) ==
             "Read [#ABC123](/b/ABC123), but keep `#ABC123 , #DEF456` as code."
  end

  test "does not link inside fenced code blocks" do
    text = """
    See #PK9ACK.

    ```sql
    SELECT '#PK9ACK';
    ```
    """

    assert BlockRefs.linkify_markdown(text,
             url_for: fn
               "PK9ACK" -> "/PK9ACK"
               _id -> nil
             end
           ) == """
           See [#PK9ACK](/PK9ACK).

           ```sql
           SELECT '#PK9ACK';
           ```
           """
  end

  test "does not link SQL keywords or numeric values as bare block ids" do
    text =
      "SELECT COUNT(*) FILTER (WHERE try_cast(total_bids AS DOUBLE)=1), tender 152877 and MIKAEL."

    assert BlockRefs.linkify_markdown(text) == text
  end

  test "extracts ids from bare text and existing links" do
    text = "See ABC234, #DEF456, [SJ3K7R], and [#GHK789](/b/GHK789)."

    assert BlockRefs.ids_from_text(text) == [
             "ABC234",
             "DEF456",
             "SJ3K7R",
             "GHK789"
           ]
  end
end
