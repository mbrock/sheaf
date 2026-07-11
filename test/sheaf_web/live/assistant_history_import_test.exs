defmodule SheafWeb.AssistantHistoryImportTest do
  use SheafWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-history-import-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    on_exit(fn ->
      File.rm(repo_path)
      File.rm(repo_path <> "-shm")
      File.rm(repo_path <> "-wal")
    end)

    :ok
  end

  test "dropping a PDF stages it and enables workspace changes", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/history")

    assert has_element?(view, "form[phx-change=validate_pdf_upload]")

    upload =
      file_input(view, "#assistant-import-pdf-drop", :pdfs, [
        %{
          name: "paper.pdf",
          content: "%PDF-1.7\nsmoke test\n",
          type: "application/pdf",
          last_modified: 1_700_000_000_000
        }
      ])

    assert render_upload(upload, "paper.pdf") =~ "paper.pdf · ready"
    html = render(view)

    assert html =~ "paper.pdf · ready"
    assert html =~ ~s(name="chat[allow_changes]")
    assert html =~ ~s(value="true" checked)
    assert html =~ ~s(value="claude-opus-4-8" selected)
    refute html =~ ~s(name="chat[mode]")
  end
end
