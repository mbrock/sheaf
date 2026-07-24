defmodule SheafWeb.SoftwareProjectLiveTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the guarded repository update action" do
    html =
      render_component(&SheafWeb.SoftwareProjectLive.render/1,
        repository_update: %{status: :idle, message: nil},
        project: %{
          title: "Moppe",
          synchronized_at: ~U[2026-07-24 21:57:50Z],
          commit_count: 1,
          source_file_count: 1,
          reference_count: 1,
          head: %{short_id: "ec9339121e"},
          recent_commits: [
            %{
              short_id: "ec9339121e",
              message: "Latest commit",
              author: "Mikael",
              committed_at: ~U[2026-07-24 20:00:00Z],
              authored_at: nil
            }
          ],
          references: [
            %{display_name: "main", kind: :branch, head?: true}
          ],
          source_files: [%{path: "README.md", language: "Markdown"}],
          repository: %{
            label: "Moppe Git repository",
            object_format: "sha1",
            identity: "remote:git@github.com:mbrock/moppe",
            checkout_path: "/home/mbrock/moppe",
            remote_url: "git@github.com:mbrock/moppe"
          }
        }
      )

    assert html =~ "Update repository"
    assert html =~ ~s(phx-click="update_repository")
    assert html =~ "Fast-forward the registered checkout"
    assert html =~ "Current source tree"
  end
end
