defmodule Sheaf.EnvTest do
  use ExUnit.Case, async: false

  test "loads env files with shell source semantics" do
    dir = System.tmp_dir!() |> Path.join("sheaf-env-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(dir)

      source = Path.join(dir, "source.env")
      env = Path.join(dir, ".env")

      File.write!(source, """
      SHEAF_ENV_SOURCE_VALUE=source
      SHEAF_ENV_DERIVED_VALUE="$SHEAF_ENV_SOURCE_VALUE-derived"
      """)

      File.write!(env, """
      SHEAF_WORKTREE_SOURCE_ENV=#{source}
      . "$SHEAF_WORKTREE_SOURCE_ENV"
      SHEAF_ENV_WORKTREE_VALUE="$SHEAF_ENV_DERIVED_VALUE-worktree"
      """)

      with_restored_env(
        ~w(SHEAF_WORKTREE_SOURCE_ENV SHEAF_ENV_SOURCE_VALUE SHEAF_ENV_DERIVED_VALUE SHEAF_ENV_WORKTREE_VALUE),
        fn ->
          assert :ok = Sheaf.Env.load_file!(env)
          assert System.get_env("SHEAF_ENV_SOURCE_VALUE") == "source"
          assert System.get_env("SHEAF_ENV_DERIVED_VALUE") == "source-derived"
          assert System.get_env("SHEAF_ENV_WORKTREE_VALUE") == "source-derived-worktree"
        end
      )
    after
      File.rm_rf!(dir)
    end
  end

  defp with_restored_env(names, fun) do
    original = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(names, &System.delete_env/1)
      fun.()
    after
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
