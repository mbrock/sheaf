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
end
