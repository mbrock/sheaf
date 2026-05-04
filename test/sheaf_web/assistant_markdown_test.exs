defmodule SheafWeb.AssistantMarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SheafWeb.AssistantMarkdownComponents

  defp render_markdown(markdown) do
    render_component(&AssistantMarkdownComponents.markdown/1, text: markdown)
  end

  test "renders markdown tables with the data table component" do
    html =
      render_markdown("""
      | Name | Count |
      | - | -: |
      | Apples | 12 |
      """)

    assert html =~ ~s(<section class="flex justify-center">)
    assert html =~ ~s(<table class="border-separate border-spacing-0 text-left">)
    assert html =~ ~s(title="Name")
    assert html =~ ~s(text-right font-mono text-sm tabular-nums)
    assert html =~ "Apples"
  end

  test "escapes raw HTML while rendering controlled table component markup" do
    html =
      render_markdown("""
      Before <script>alert(1)</script>

      | Name |
      | - |
      | <b>Bold</b> |
      """)

    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;b&gt;Bold&lt;/b&gt;"
    refute html =~ "<b>Bold</b>"
    assert html =~ ~s(<table class="border-separate border-spacing-0 text-left">)
  end
end
