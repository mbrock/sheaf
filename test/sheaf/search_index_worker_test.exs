defmodule Sheaf.SearchIndexWorkerTest do
  use ExUnit.Case, async: false

  test "publishes search and embedding progress without blocking the caller" do
    test_pid = self()

    search_sync = fn ->
      send(test_pid, :search_started)
      {:ok, %{count: 12}}
    end

    embedding_sync = fn opts ->
      opts[:notify].({:planned, 12, 3, 9})
      opts[:notify].({:progress, 2, 3, 0})
      opts[:notify].({:vectors, 12})

      {:ok,
       %{
         target_count: 12,
         embedded_count: 3,
         skipped_count: 9,
         error_count: 0,
         status: "completed"
       }}
    end

    Phoenix.PubSub.subscribe(
      Sheaf.PubSub,
      Sheaf.SearchIndexWorker.topic()
    )

    start_supervised!(
      {Sheaf.SearchIndexWorker,
       search_sync: search_sync, embedding_sync: embedding_sync}
    )

    assert :ok = Sheaf.SearchIndexWorker.enqueue("test import")
    assert_receive :search_started

    assert_receive {:search_index_status,
                    %{phase: :embedding, completed_count: 2, total_count: 3}}

    assert_receive {:search_index_status,
                    %{
                      phase: :vectors,
                      message: "Publishing 12 search vectors"
                    }}

    assert_receive {:search_index_status,
                    %{phase: :complete, running?: false}}

    assert Sheaf.SearchIndexWorker.status().message == "Search is up to date"
  end
end
