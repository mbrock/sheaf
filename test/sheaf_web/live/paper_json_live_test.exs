defmodule SheafWeb.PaperJsonLiveTest do
  use SheafWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @tag :tmp_dir
  test "renders Datalab JSON pages and inlines companion images", %{conn: conn, tmp_dir: tmp_dir} do
    json_path = Path.join(tmp_dir, "paper.json")
    result_path = Path.join(tmp_dir, "result.json")

    File.write!(
      json_path,
      Jason.encode!(%{
        "children" => [
          %{
            "children" => [
              %{
                "bbox" => [1.0, 2.0, 3.0, 4.0],
                "block_type" => "SectionHeader",
                "html" => "<h1>Hello section</h1>",
                "id" => "/page/0/SectionHeader/0",
                "page" => 0
              },
              %{
                "bbox" => [5.0, 6.0, 7.0, 8.0],
                "block_type" => "Picture",
                "html" => ~s(<img alt="sample" src="sample_img.jpg"/>),
                "id" => "/page/0/Picture/1",
                "page" => 0
              }
            ],
            "id" => "/page/0/Page/0"
          }
        ],
        "metadata" => %{}
      })
    )

    File.write!(result_path, Jason.encode!(%{"images" => %{"sample_img.jpg" => "QUJD"}}))

    previous = Application.get_env(:sheaf, SheafWeb.PaperJsonLive)

    Application.put_env(:sheaf, SheafWeb.PaperJsonLive,
      json_path: json_path,
      result_path: result_path
    )

    try do
      {:ok, _view, html} = live(conn, ~p"/papers/kappa/datalab-json")

      assert html =~ "Datalab JSON"
      assert html =~ "Hello section"
      assert html =~ "SectionHeader"
      assert html =~ "data:image/jpeg;base64,QUJD"
    after
      if previous do
        Application.put_env(:sheaf, SheafWeb.PaperJsonLive, previous)
      else
        Application.delete_env(:sheaf, SheafWeb.PaperJsonLive)
      end
    end
  end
end
