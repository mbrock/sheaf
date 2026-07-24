defmodule SheafWeb.WorkspaceEntryComponentsTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SheafWeb.WorkspaceEntryComponents

  test "software project cards link to the unified resource route" do
    html =
      render_component(&software_project_card/1,
        project: %{
          path: "/PROJ01",
          title: "Moppe",
          commit_count: 440,
          source_file_count: 339,
          head: %{short_id: "ec9339121e"},
          head_references: [%{display_name: "master"}],
          repository: %{label: "Moppe Git repository"}
        }
      )

    assert html =~ ~s(href="/PROJ01")
    assert html =~ "Software project"
    assert html =~ "Moppe"
    assert html =~ "ec9339121e"
    assert html =~ "440 commits"
    assert html =~ "339 files"
  end
end
