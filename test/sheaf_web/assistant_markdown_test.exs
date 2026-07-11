defmodule SheafWeb.AssistantMarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SheafWeb.AssistantMarkdownComponents

  defp render_markdown(markdown, opts \\ []) do
    assigns =
      Keyword.merge(
        [
          text: markdown,
          resource_paths: %{
            "DOC111" => "/DOC111",
            "PAR111" => "/b/PAR111",
            "PAR222" => "/b/PAR222",
            "PAR333" => "/b/PAR333"
          }
        ],
        opts
      )

    render_component(&AssistantMarkdownComponents.markdown/1, assigns)
  end

  test "renders markdown tables with the data table component" do
    html =
      render_markdown("""
        | Name | Count |
        | - | -: |
        | Apples | 12 |
      """)

    assert html =~
             ~s(<section class="flex max-w-full flex-col items-center">)

    assert html =~
             ~s(<table class="border-separate border-spacing-0 text-left" id="data-table-)

    assert html =~ ~s(phx-hook="DataTable")
    assert html =~ ~s(data-table-heading-label)
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

    assert html =~
             ~s(<table class="border-separate border-spacing-0 text-left" id="data-table-)

    assert html =~ ~s(phx-hook="DataTable")
  end

  test "renders images without changing their aspect ratio" do
    html =
      render_markdown(
        "![A generated landscape](https://example.com/landscape.png)"
      )

    assert html =~ ~s(class="h-auto max-w-full object-contain")
    assert html =~ ~s(src="https://example.com/landscape.png")
    assert html =~ ~s(alt="A generated landscape")
  end

  test "renders inline and display LaTeX as math sources for KaTeX" do
    html =
      render_markdown("""
      Euler wrote $e^{i\\pi} + 1 = 0$ and also \\(a^2+b^2=c^2\\).

      $$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$$

      \\[\\sum_{k=1}^n k = \\frac{n(n+1)}{2}\\]
      """)

    compact_html =
      html
      |> String.replace(~r/>\s+/, ">")
      |> String.replace(~r/\s+</, "<")

    assert compact_html =~ ~s(<math>e^{i\\pi} + 1 = 0</math>)
    assert compact_html =~ ~s(<math>a^2+b^2=c^2</math>)

    assert compact_html =~
             ~s(<math display="block">\\int_0^1 x^2 \\, dx = \\frac{1}{3}</math>)

    assert compact_html =~
             ~s|<math display="block">\\sum_{k=1}^n k = \\frac{n(n+1)}{2}</math>|
  end

  test "renders numeric inline LaTeX without treating currency as mathematics" do
    html = render_markdown("The area is $25 \\times 25\\ \\mathrm{km}^2$.")

    compact_html =
      html
      |> String.replace(~r/>\s+/, ">")
      |> String.replace(~r/\s+</, "<")

    assert compact_html =~ ~s(<math>25 \\times 25\\ \\mathrm{km}^2</math>)
  end

  test "does not treat currency or code as mathematics" do
    html =
      render_markdown("""
      The papers cost between $5 and $10. Use `$x^2$` to show the syntax.

      ```latex
      $$x^2$$
      ```
      """)

    assert html =~ "between $5 and $10"
    assert html =~ "<code>$x^2$</code>"
    assert html =~ "<pre><code"
    assert html =~ "$$x^2$$"
    refute html =~ "<math"
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

    assert html =~
             ~s(class="block-preview-trigger resource-ref cursor-pointer")

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

    assert html =~
             ~r/>PAR111<\/button>\s*<\/span>\s+<span class="whitespace-nowrap small-caps">\s*<button[^>]+>PAR222<\/button>\.\s*<\/span>/

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

    assert html =~
             ~r/See\s+<span class="whitespace-nowrap small-caps">\s*<button[^>]+>PAR111<\/button>\.\s*<\/span>/

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

    assert html =~
             ~r/>PAR222<\/button>\s*<\/span>\s+<span class="whitespace-nowrap small-caps">\s*<button[^>]+>PAR333<\/button>\.\s*<\/span>/

    refute html =~ "(PAR111"
    refute html =~ "(PAR222"
    refute html =~ "PAR222,"
    refute html =~ "PAR333)"
  end
end
