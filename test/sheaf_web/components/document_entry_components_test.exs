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

    assert html =~ ~r/>\s*draft\s*<\/span>/
  end

  test "renders a Mikael status pill" do
    html =
      render_component(&document_entry/1,
        document: %{
          id: "DOC2",
          kind: :thesis,
          path: "/DOC2",
          title: "Mikael thesis",
          metadata: %{status: "mikael"},
          excluded?: false,
          cited?: false,
          has_document?: true,
          workspace_owner_authored?: true
        }
      )

    assert html =~ ~r/>\s*MIKAEL\s*<\/span>/
  end

  test "metadata heading uses plain compact metadata" do
    html =
      render_component(&document_metadata_heading/1,
        document: %{
          id: "DOC3",
          kind: :paper,
          path: "/DOC3",
          title: "Circulation of Things",
          metadata: %{year: 2026, authors: ["Lange"]},
          excluded?: false,
          cited?: false,
          has_document?: true
        },
        show_open?: false
      )

    assert html =~ "2026"
    assert html =~ "Lange"
    refute html =~ "small-caps shrink-0 tabular-nums"
    refute html =~ "small-caps min-w-0 flex-1 truncate"
  end
end
