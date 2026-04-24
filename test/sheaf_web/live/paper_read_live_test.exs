defmodule SheafWeb.PaperReadLiveTest do
  use SheafWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @tag :tmp_dir
  test "renders Datalab JSON as nested reader blocks", %{conn: conn, tmp_dir: tmp_dir} do
    json_path = Path.join(tmp_dir, "paper.json")

    File.write!(
      json_path,
      Jason.encode!(%{
        "children" => [
          %{
            "children" => [
              %{
                "block_type" => "SectionHeader",
                "html" => "<h1>Hello section</h1>",
                "id" => "/page/0/SectionHeader/0",
                "section_hierarchy" => %{}
              },
              %{
                "block_type" => "SectionHeader",
                "html" => "<h2>Child section</h2>",
                "id" => "/page/0/SectionHeader/1",
                "section_hierarchy" => %{"1" => "/page/0/SectionHeader/0"}
              },
              %{
                "block_type" => "Picture",
                "html" => ~s(<p><img src="figure.png" alt="figure"/></p>),
                "id" => "/page/0/Picture/1",
                "images" => %{"figure.png" => "QUJD"},
                "section_hierarchy" => %{
                  "1" => "/page/0/SectionHeader/0",
                  "2" => "/page/0/SectionHeader/1"
                }
              }
            ],
            "id" => "/page/0/Page/0"
          }
        ],
        "metadata" => %{}
      })
    )

    previous = Application.get_env(:sheaf, SheafWeb.PaperReadLive)
    Application.put_env(:sheaf, SheafWeb.PaperReadLive, json_path: json_path)

    try do
      {:ok, _view, html} = live(conn, ~p"/papers/kappa/read")

      assert html =~ ~s(id="paper-block-page-0-SectionHeader-0")
      assert html =~ ~s(href="#paper-block-page-0-SectionHeader-1")
      assert html =~ "Hello section"
      assert html =~ "Child section"
      assert html =~ "data:image/png;base64,QUJD"
    after
      if previous do
        Application.put_env(:sheaf, SheafWeb.PaperReadLive, previous)
      else
        Application.delete_env(:sheaf, SheafWeb.PaperReadLive)
      end
    end
  end
end
