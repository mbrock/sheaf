defmodule SheafTest do
  use ExUnit.Case, async: true

  test "rpc_eval returns successful values" do
    assert {:ok, 42} = Sheaf.rpc_eval(Process.group_leader(), "40 + 2")
  end

  test "rpc_eval returns formatted syntax and runtime errors" do
    assert {:error, syntax_error} = Sheaf.rpc_eval(Process.group_leader(), "1 +")
    assert syntax_error =~ "TokenMissingError"
    assert syntax_error =~ "bin/rpc"

    assert {:error, runtime_error} = Sheaf.rpc_eval(Process.group_leader(), "raise \"boom\"")
    assert runtime_error =~ "RuntimeError"
    assert runtime_error =~ "boom"
  end
end
