defmodule SheafRDFBrowser.SnapshotTest do
  use ExUnit.Case, async: false

  alias SheafRDFBrowser.Snapshot

  setup do
    original = Application.get_env(:sheaf_rdf_browser, Snapshot)

    on_exit(fn ->
      Application.put_env(:sheaf_rdf_browser, Snapshot, original)
    end)

    :ok
  end

  test "load on start does not crash when the configured pubsub is not running" do
    Application.put_env(:sheaf_rdf_browser, Snapshot,
      dataset: fn -> {:ok, RDF.Dataset.new()} end,
      load_on_start: true,
      pubsub: SheafRDFBrowser.MissingPubSub
    )

    assert %Snapshot{status: :ready} = Snapshot.refresh()
  end
end
