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

  test "renders block reference buttons for LiveView preview loading" do
    html =
      render_markdown("See [#PAR111](/b/PAR111).",
        block_ref_target: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(<button)
    assert html =~ ~s(type="button")
    assert html =~ ~s(phx-click="show_resource_preview")
    assert html =~ ~s(phx-value-id="PAR111")
    assert html =~ ~s(phx-target="1")
    refute html =~ ~s(role="tooltip")
    refute html =~ "block-preview-backdrop"
    refute html =~ "backdrop-blur"
    refute html =~ "block-preview-card"
  end

  test "renders document reference buttons for LiveView preview loading" do
    html =
      render_markdown("See [#DOC111](/DOC111).",
        block_ref_target: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~s(<button)
    assert html =~ ~s(aria-label="#DOC111")
    assert html =~ ~s(phx-click="show_resource_preview")
    assert html =~ ~s(phx-value-id="DOC111")
    assert html =~ ">DOC111</button>"
    refute html =~ ">#DOC111</button>"
  end

  test "renders parenthesized reference lists without parens or commas" do
    html =
      render_markdown("See ([#PAR111](/b/PAR111) , [#PAR222](/b/PAR222) ).",
        block_ref_target: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~r/>PAR111<\/button>\s*<\/span>\s+<span class="whitespace-nowrap">\s*<button[^>]+>PAR222<\/button>\.\s*<\/span>/
    refute html =~ "(PAR111"
    refute html =~ "PAR111,"
    refute html =~ "PAR222)"
    refute html =~ ","
    refute html =~ ")"
  end

  test "renders a single parenthesized reference without parens" do
    html =
      render_markdown("See ([#PAR111](/b/PAR111)). More.",
        block_ref_target: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~r/See\s+<span class="whitespace-nowrap">\s*<button[^>]+>PAR111<\/button>\.\s*<\/span>/
    assert html =~ "More."
    refute html =~ "(PAR111"
    refute html =~ "PAR111)"
    refute html =~ ")"
  end

  test "renders multiple parenthesized reference groups in one paragraph" do
    html =
      render_markdown(
        "First ([#PAR111](/b/PAR111)). Later ([#PAR222](/b/PAR222), [#PAR333](/b/PAR333)).",
        block_ref_target: %Phoenix.LiveComponent.CID{cid: 1}
      )

    assert html =~ ~r/>PAR111<\/button>\.\s*<\/span>/
    assert html =~ ~r/>PAR222<\/button>\s*<\/span>\s+<span class="whitespace-nowrap">\s*<button[^>]+>PAR333<\/button>\.\s*<\/span>/
    refute html =~ "(PAR111"
    refute html =~ "(PAR222"
    refute html =~ "PAR222,"
    refute html =~ "PAR333)"
  end
end
