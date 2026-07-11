defmodule Datalab.DocumentTest do
  use ExUnit.Case, async: true

  alias Datalab.Document

  test "extracts LaTeX and reports mathematical extraction quality" do
    document = %{
      "children" => [
        %{
          "children" => [
            %{
              "block_type" => "Text",
              "html" => "<p>Let <math>x &amp; y</math> be values.</p>",
              "page" => 0
            },
            %{
              "block_type" => "Equation",
              "html" =>
                ~s(<p><math display="block">\\frac{x}{y}=2</math></p>),
              "page" => 0
            },
            %{
              "block_type" => "Equation",
              "html" => "<p>unparsed equation image</p>",
              "page" => 1
            }
          ]
        }
      ]
    }

    [text, equation, _empty] = hd(document["children"])["children"]
    assert Document.math_expressions(text) == ["x & y"]
    assert Document.math_expressions(equation) == [~s(\\frac{x}{y}=2)]

    assert %{
             pages: 1,
             blocks: 3,
             block_types: %{"Equation" => 2, "Text" => 1},
             equation_blocks: 2,
             math_expressions: 2,
             pages_with_math: 1,
             empty_equation_blocks: 1
           } = Document.quality_report(document)
  end

  test "reconstructs conservative text continuations across page furniture" do
    document = %{
      "children" => [
        %{
          "children" => [
            %{
              "block_type" => "Text",
              "html" => "<p>A generated sec-</p>",
              "id" => "/page/0/Text/0",
              "page" => 0,
              "section_hierarchy" => %{"1" => "intro"}
            }
          ]
        },
        %{
          "children" => [
            %{
              "block_type" => "Picture",
              "html" => "<p>Figure</p>",
              "id" => "/page/1/Picture/0",
              "page" => 1,
              "section_hierarchy" => %{"1" => "intro"}
            },
            %{
              "block_type" => "Caption",
              "html" => "<p>Figure 1.</p>",
              "id" => "/page/1/Caption/1",
              "page" => 1,
              "section_hierarchy" => %{"1" => "intro"}
            },
            %{
              "block_type" => "Text",
              "html" => "<p>tion continues here.</p>",
              "id" => "/page/1/Text/2",
              "page" => 1,
              "section_hierarchy" => %{"1" => "intro"}
            }
          ]
        }
      ]
    }

    assert [candidate] = Document.page_continuations(document)
    assert candidate.page_start == 0
    assert candidate.page_end == 1

    [text, picture, caption] = Document.document_blocks(document)
    assert text.block["html"] == "<p>A generated section continues here.</p>"

    assert Document.source_keys(text.block) == [
             "/page/0/Text/0",
             "/page/1/Text/2"
           ]

    assert Document.source_page(text.block) == 0
    assert Document.source_page_end(text.block) == 1
    assert picture.block["block_type"] == "Picture"
    assert caption.block["block_type"] == "Caption"
    assert Document.quality_report(document).page_continuations == 1
  end

  test "does not reconstruct across semantic blocks" do
    pages = [
      %{
        "children" => [
          %{
            "block_type" => "Text",
            "html" => "<p>An unfinished thought</p>",
            "id" => "text-1",
            "page" => 0,
            "section_hierarchy" => %{}
          },
          %{
            "block_type" => "Equation",
            "html" => "<p><math>x=1</math></p>",
            "id" => "equation-1",
            "page" => 0,
            "section_hierarchy" => %{}
          }
        ]
      },
      %{
        "children" => [
          %{
            "block_type" => "Text",
            "html" => "<p>where the explanation continues.</p>",
            "id" => "text-2",
            "page" => 1,
            "section_hierarchy" => %{}
          }
        ]
      }
    ]

    assert Document.page_continuations(pages) == []
    assert length(Document.document_blocks(pages)) == 3
  end
end
