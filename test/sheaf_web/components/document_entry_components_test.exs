defmodule SheafWeb.DocumentEntryComponentsTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SheafWeb.DocumentEntryComponents

  test "renders metadata-only index checkboxes disabled and unchecked" do
    html =
      render_component(&document_entry/1,
        document: %{
          id: "WORK1",
          kind: :paper,
          path: nil,
          title: "Metadata-only work",
          metadata: %{},
          excluded?: false,
          cited?: false,
          has_document?: false
        },
        show_checkbox: true
      )

    assert html =~ ~s(type="checkbox")
    assert html =~ "disabled"
    refute html =~ "checked"
  end

  test "renders a draft status pill" do
    html =
      render_component(&document_entry/1,
        document: %{
          id: "DOC1",
          kind: :thesis,
          path: "/DOC1",
          title: "Draft thesis",
          metadata: %{status: "draft"},
          excluded?: false,
          cited?: false,
          has_document?: true,
          workspace_owner_authored?: true
        }
      )

    assert html =~ ">draft</span>"
  end
end
