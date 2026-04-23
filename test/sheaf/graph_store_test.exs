defmodule Sheaf.GraphStoreTest do
  use ExUnit.Case, async: false

  alias Sheaf.GraphStore

  test "default_http_headers builds basic auth from config" do
    previous_config = Application.get_env(:sheaf, Sheaf.GraphStore)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sheaf, Sheaf.GraphStore, previous_config)
      else
        Application.delete_env(:sheaf, Sheaf.GraphStore)
      end
    end)

    Application.put_env(:sheaf, Sheaf.GraphStore,
      username: "alice",
      password: "secret"
    )

    assert %{"Authorization" => "Basic " <> encoded} = GraphStore.default_http_headers(nil, %{})
    assert Base.decode64!(encoded) == "alice:secret"
  end

  test "default_http_headers omits auth when credentials are incomplete" do
    previous_config = Application.get_env(:sheaf, Sheaf.GraphStore)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sheaf, Sheaf.GraphStore, previous_config)
      else
        Application.delete_env(:sheaf, Sheaf.GraphStore)
      end
    end)

    Application.put_env(:sheaf, Sheaf.GraphStore, username: "alice")

    assert %{} == GraphStore.default_http_headers(nil, %{})
  end
end
