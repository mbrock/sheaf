defmodule Sheaf.TaskQueue.StoreTest do
  use ExUnit.Case, async: true

  alias Sheaf.TaskQueue.Store

  test "creates a batch, claims tasks, and rolls up completion counts" do
    {:ok, conn} = Store.open(db_path: ":memory:")
    on_exit(fn -> Store.close(conn) end)

    assert {:ok, batch} =
             Store.create_batch(
               conn,
               %{
                 iri: "https://sheaf.less.rest/BATCH1",
                 queue: "metadata",
                 kind: "metadata.resolve",
                 input: %{scope: "test"}
               },
               [
                 %{
                   kind: "metadata.scan_identifiers",
                   subject_iri: "https://sheaf.less.rest/DOC1",
                   identifier: "DOC1",
                   unique_key: "metadata.scan_identifiers:https://sheaf.less.rest/DOC1",
                   input: %{document: "https://sheaf.less.rest/DOC1"}
                 }
               ]
             )

    assert batch.target_count == 1

    assert {:ok, task} = Store.claim_task(conn, queue: "metadata", worker: "test")
    assert task.status == "running"
    assert task.attempts == 1

    assert :ok = Store.complete_task(conn, task.id, %{found: ["10.1000/example"]})
    assert {:ok, batch} = Store.get_batch(conn, "https://sheaf.less.rest/BATCH1")
    assert batch.status == "completed"
    assert batch.completed_count == 1

    assert {:ok, nil} = Store.claim_task(conn, queue: "metadata", worker: "test")
  end

  test "retries failed tasks until max attempts" do
    {:ok, conn} = Store.open(db_path: ":memory:")
    on_exit(fn -> Store.close(conn) end)

    assert {:ok, _batch} =
             Store.create_batch(
               conn,
               %{
                 iri: "https://sheaf.less.rest/BATCH2",
                 queue: "metadata",
                 kind: "metadata.resolve"
               },
               [
                 %{
                   kind: "metadata.crossref.lookup",
                   unique_key: "metadata.crossref.lookup:10.1000/example",
                   identifier: "10.1000/example",
                   max_attempts: 1
                 }
               ]
             )

    assert {:ok, task} = Store.claim_task(conn, queue: "metadata", worker: "test")
    assert :ok = Store.fail_task(conn, task.id, :nope)

    assert {:ok, [task]} = Store.list_tasks(conn, status: "failed")
    assert task.error["message"] =~ ":nope"

    assert {:ok, batch} = Store.get_batch(conn, "https://sheaf.less.rest/BATCH2")
    assert batch.status == "failed"
    assert batch.failed_count == 1
  end

  test "creates a follow-up task in an existing batch" do
    {:ok, conn} = Store.open(db_path: ":memory:")
    on_exit(fn -> Store.close(conn) end)

    assert {:ok, batch} =
             Store.create_batch(
               conn,
               %{
                 iri: "https://sheaf.less.rest/BATCH3",
                 queue: "metadata",
                 kind: "metadata.resolve"
               },
               [
                 %{
                   kind: "metadata.extract_identifiers",
                   unique_key: "metadata.extract_identifiers:https://sheaf.less.rest/DOC1",
                   subject_iri: "https://sheaf.less.rest/DOC1"
                 }
               ]
             )

    assert batch.target_count == 1

    assert {:ok, task} =
             Store.create_task(
               conn,
               "https://sheaf.less.rest/BATCH3",
               %{queue: "metadata"},
               %{
                 kind: "metadata.crossref.lookup",
                 unique_key:
                   "metadata.crossref.lookup:https://sheaf.less.rest/DOC1:10.1000/example",
                 subject_iri: "https://sheaf.less.rest/DOC1",
                 identifier: "10.1000/example",
                 input: %{doi: "10.1000/example"}
               }
             )

    assert task.kind == "metadata.crossref.lookup"
    assert task.input["doi"] == "10.1000/example"

    assert {:ok, batch} = Store.get_batch(conn, "https://sheaf.less.rest/BATCH3")
    assert batch.target_count == 2
  end

  test "claims pending tasks by kind" do
    {:ok, conn} = Store.open(db_path: ":memory:")
    on_exit(fn -> Store.close(conn) end)

    assert {:ok, _batch} =
             Store.create_batch(
               conn,
               %{
                 iri: "https://sheaf.less.rest/BATCH4",
                 queue: "metadata",
                 kind: "metadata.resolve"
               },
               [
                 %{
                   kind: "metadata.extract_identifiers",
                   unique_key: "metadata.extract_identifiers:https://sheaf.less.rest/DOC1"
                 },
                 %{
                   kind: "metadata.crossref.lookup",
                   unique_key:
                     "metadata.crossref.lookup:https://sheaf.less.rest/DOC1:10.1000/example"
                 }
               ]
             )

    assert {:ok, task} =
             Store.claim_task(conn,
               queue: "metadata",
               kind: "metadata.crossref.lookup",
               worker: "test"
             )

    assert task.kind == "metadata.crossref.lookup"
  end
end
