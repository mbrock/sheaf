defmodule SheafWeb.AssistantToolResultComponentsTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SheafWeb.AssistantToolResultComponents

  alias Sheaf.Assistant.ToolResults

  test "renders a generated image as a visible tool artifact" do
    html =
      render_component(&tool_preview_body/1,
        message: %{
          result: %ToolResults.GeneratedImage{
            image_id: "IMG123",
            path: "/images/IMG123",
            prompt: "An archipelago of paper islands",
            model: "gpt-image-2"
          }
        },
        tool_view: %{}
      )

    assert html =~ ~s(src="/images/IMG123")
    assert html =~ "An archipelago of paper islands"
    assert html =~ "image #IMG123"
    assert html =~ "gpt-image-2"
  end

  test "renders web search sources restored from JSON" do
    html =
      render_component(&tool_preview_body/1,
        message: %{
          result: %ToolResults.WebSearch{
            text: "An answer",
            sources: [
              %{
                "title" => "Basic Formal Ontology (BFO) | Home",
                "url" => "https://bfo-ontology.github.io/bfo-2020.html"
              }
            ]
          }
        },
        tool_view: %{}
      )

    assert html =~ "Basic Formal Ontology (BFO) | Home"
    assert html =~ ~s(href="https://bfo-ontology.github.io/bfo-2020.html")
  end
end
