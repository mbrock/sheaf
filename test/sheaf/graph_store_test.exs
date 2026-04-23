defmodule Sheaf.GraphStoreTest do
  use ExUnit.Case, async: false

  alias Sheaf.GraphStore

  setup do
    previous_config = Application.get_env(:sheaf, Sheaf.GraphStore)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sheaf, Sheaf.GraphStore, previous_config)
      else
        Application.delete_env(:sheaf, Sheaf.GraphStore)
      end
    end)

    :ok
  end

  test "default_http_headers builds basic auth from config" do
    Application.put_env(:sheaf, Sheaf.GraphStore,
      username: "alice",
      password: "secret"
    )

    assert %{"Authorization" => "Basic " <> encoded} = GraphStore.default_http_headers(nil, %{})
    assert Base.decode64!(encoded) == "alice:secret"
  end

  test "default_http_headers omits auth when credentials are incomplete" do
    Application.put_env(:sheaf, Sheaf.GraphStore, username: "alice")

    assert %{} == GraphStore.default_http_headers(nil, %{})
  end

  test "backup_graphs returns the configured graph list without duplicates" do
    Application.put_env(:sheaf, Sheaf.GraphStore,
      graph: "https://less.rest/sheaf/graph/main",
      backup_graphs: [
        "https://less.rest/sheaf/graph/main",
        "https://less.rest/sheaf/graph/interviews",
        "https://less.rest/sheaf/graph/main"
      ]
    )

    assert GraphStore.backup_graphs() == [
             "https://less.rest/sheaf/graph/main",
             "https://less.rest/sheaf/graph/interviews"
           ]
  end

  test "backup_graphs falls back to the default graph" do
    Application.put_env(:sheaf, Sheaf.GraphStore, graph: "https://less.rest/sheaf/graph/main")

    assert GraphStore.backup_graphs() == ["https://less.rest/sheaf/graph/main"]
  end

  test "backup_graphs falls back to the default graph when configured list is empty" do
    Application.put_env(:sheaf, Sheaf.GraphStore,
      graph: "https://less.rest/sheaf/graph/main",
      backup_graphs: []
    )

    assert GraphStore.backup_graphs() == ["https://less.rest/sheaf/graph/main"]
  end
end
