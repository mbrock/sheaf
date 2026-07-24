defmodule Sheaf.PDFImportTest do
  use ExUnit.Case, async: false

  alias Sheaf.NS.DOC

  setup do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-pdf-import-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    on_exit(fn ->
      File.rm(repo_path)
      File.rm(repo_path <> "-shm")
      File.rm(repo_path <> "-wal")
    end)

    :ok
  end

  test "commits PDF content and source metadata atomically" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-pdf-import-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "children" => [
          %{
            "children" => [
              %{
                "block_type" => "Text",
                "html" => "<p>Imported text</p>",
                "id" => "/page/0/Text/0",
                "page" => 0,
                "section_hierarchy" => %{}
              }
            ]
          }
        ],
        "metadata" => %{}
      })
    )

    on_exit(fn -> File.rm(path) end)

    source_file = Sheaf.Id.iri("SOURCE")

    assert {:ok, result} =
             Sheaf.PDF.import_file(path, source_file_iri: source_file)

    assert {:ok, content_rows} =
             Sheaf.Repo.match_rows({nil, nil, nil, result.document})

    assert content_rows != []

    assert {:ok, metadata_rows} =
             Sheaf.Repo.match_rows(
               {result.document, DOC.sourceFile(), source_file, nil}
             )

    assert [_source_link] = metadata_rows
  end
end
