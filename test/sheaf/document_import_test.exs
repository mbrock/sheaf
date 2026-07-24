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

  test "retries reuse the document already committed for a source file", %{
    blob_root: root
  } do
    pdf_path =
      Path.join(
        System.tmp_dir!(),
        "document-import-idempotent-#{System.unique_integer([:positive])}.pdf"
      )

    output_path =
      Path.join(
        System.tmp_dir!(),
        "document-import-idempotent-#{System.unique_integer([:positive])}.json"
      )

    File.write!(pdf_path, "%PDF-1.7\n")

    File.write!(
      output_path,
      Jason.encode!(%{"children" => [], "metadata" => %{}})
    )

    on_exit(fn ->
      File.rm(pdf_path)
      File.rm(output_path)
    end)

    assert {:ok, stored} =
             Sheaf.Files.ingest(pdf_path,
               blob_root: root,
               filename: "paper.pdf",
               mime_type: "application/pdf"
             )

    assert {:ok, staged} =
             Sheaf.DocumentImport.stage(%{
               "file_ids" => [Sheaf.Id.id_from_iri(stored.iri)],
               "name" => "Idempotent import"
             })

    assert {:ok, _file_job} =
             Sheaf.DatalabJobs.update_file_job(
               staged.run_iri,
               stored.iri,
               output_path: output_path,
               completed_at: DateTime.utc_now()
             )

    assert {:ok, first} =
             Sheaf.DocumentImport.import_run(%{"run_id" => staged.run_id})

    assert [%{status: "imported", document_id: document_id}] =
             first.documents

    assert {:ok, second} =
             Sheaf.DocumentImport.import_run(%{"run_id" => staged.run_id})

    assert [
             %{
               status: "already_imported",
               document_id: ^document_id
             }
           ] = second.documents

    assert {:ok, source_rows} =
             Sheaf.Repo.match_rows(
               {nil, Sheaf.NS.DOC.sourceFile(), stored.iri, nil}
             )

    assert [_single_source_link] = source_rows
  end
end
