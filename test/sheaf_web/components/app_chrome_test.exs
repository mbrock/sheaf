defmodule SheafWeb.AppChromeTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SheafWeb.AppChrome

  test "renders optional PDF export link in the toolbar" do
    html =
      render_component(&toolbar/1,
        section: :document,
        pdf_export_path: "/api/documents/DOC123/pdf"
      )

    assert html =~ ~s(href="/api/documents/DOC123/pdf")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ "Open PDF export"
  end
end
