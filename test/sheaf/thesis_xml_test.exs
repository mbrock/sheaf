defmodule Sheaf.ThesisXmlTest do
  use ExUnit.Case, async: true

  alias Sheaf.ThesisXml

  test "parse_string nests headings into section blocks" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <doc>
    <p>A Very Long Thesis Title About Material Circulation</p>
    <p>Front matter.</p>
    <h1>Introduction</h1>
    <p>Opening paragraph.</p>
    <h2>Background</h2>
    <p>Nested paragraph.</p>
    <h1>Conclusion</h1>
    <p>Closing paragraph.</p>
    </doc>
    """

    assert {:ok, document} = ThesisXml.parse_string(xml, "sample.xml")

    assert document.title == "A Very Long Thesis Title About Material Circulation"

    assert document.blocks == [
             {:paragraph, "A Very Long Thesis Title About Material Circulation"},
             {:paragraph, "Front matter."},
             {:section, "Introduction",
              [
                {:paragraph, "Opening paragraph."},
                {:section, "Background", [{:paragraph, "Nested paragraph."}]}
              ]},
             {:section, "Conclusion", [{:paragraph, "Closing paragraph."}]}
           ]
  end
end
