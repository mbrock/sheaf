defmodule Sheaf.FusekiTest do
  use ExUnit.Case, async: false

  alias Sheaf.Fuseki

  test "default_http_headers builds basic auth from config" do
    previous_config = Application.get_env(:sheaf, Sheaf.Fuseki)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sheaf, Sheaf.Fuseki, previous_config)
      else
        Application.delete_env(:sheaf, Sheaf.Fuseki)
      end
    end)

    Application.put_env(:sheaf, Sheaf.Fuseki,
      username: "alice",
      password: "secret"
    )

    assert %{"Authorization" => "Basic " <> encoded} = Fuseki.default_http_headers(nil, %{})
    assert Base.decode64!(encoded) == "alice:secret"
  end

  test "default_http_headers omits auth when credentials are incomplete" do
    previous_config = Application.get_env(:sheaf, Sheaf.Fuseki)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:sheaf, Sheaf.Fuseki, previous_config)
      else
        Application.delete_env(:sheaf, Sheaf.Fuseki)
      end
    end)

    Application.put_env(:sheaf, Sheaf.Fuseki, username: "alice")

    assert %{} == Fuseki.default_http_headers(nil, %{})
  end
end
