defmodule Sheaf.DocumentImportTest do
  use ExUnit.Case, async: false

  setup do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-import-#{System.unique_integer([:positive])}.sqlite3"
      )

    blob_root =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-import-blobs-#{System.unique_integer([:positive])}"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    on_exit(fn ->
      File.rm(repo_path)
      File.rm(repo_path <> "-shm")
      File.rm(repo_path <> "-wal")
      File.rm_rf(blob_root)
    end)

    %{blob_root: blob_root}
  end

  test "stages uploaded file ids into a durable import run", %{
    blob_root: root
  } do
    path = Path.join(System.tmp_dir!(), "document-import-test.pdf")
    File.write!(path, "%PDF-1.7\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, stored} =
             Sheaf.Files.ingest(path,
               blob_root: root,
               filename: "paper.pdf",
               mime_type: "application/pdf"
             )

    assert {:ok, result} =
             Sheaf.DocumentImport.stage(%{
               "file_ids" => [Sheaf.Id.id_from_iri(stored.iri)],
               "name" => "Test import"
             })

    assert result.action == "stage"
    assert result.file_ids == [Sheaf.Id.id_from_iri(stored.iri)]
    assert result.status.counts == %{"pending" => 1}

    assert {:ok, status} =
             Sheaf.DocumentImport.status(%{"run_id" => result.run_id})

    assert status.status.counts == %{"pending" => 1}
  end
end
