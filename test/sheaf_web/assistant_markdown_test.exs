defmodule SheafWeb.AssistantMarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SheafWeb.AssistantMarkdownComponents

  defp render_markdown(markdown, opts \\ []) do
    assigns = Keyword.merge([text: markdown], opts)

    render_component(&AssistantMarkdownComponents.markdown/1, assigns)
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

  test "renders block reference hover cards when a preview is available" do
    html =
      render_markdown("See [#PAR111](/b/PAR111).",
        block_previews: %{
          "PAR111" => %{
            id: "PAR111",
            text: "The paragraph text appears here.",
            document_id: "DOC111",
            document_title: "Thesis draft",
            document_authors: ["Mikael Brockman"],
            document_year: "2026",
            section_id: "SEC111",
            section_title: "Freecycling"
          }
        }
      )

    assert html =~ ~s(<button)
    assert html =~ ~s(type="button")
    assert html =~ ~s(role="tooltip")
    assert html =~ "block-preview-backdrop"
    refute html =~ "backdrop-blur"
    assert html =~ "block-preview-card"
    assert html =~ "Thesis draft"
    assert html =~ "Mikael Brockman"
    assert html =~ "2026"
    assert html =~ "Freecycling"
    refute html =~ "#DOC111"
    refute html =~ "#SEC111"
    assert html =~ "The paragraph text appears here."
    assert html =~ ~s(aria-label="Open page")
    assert html =~ ~s(href="/b/PAR111")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
  end
end
