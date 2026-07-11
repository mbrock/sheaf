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
end
