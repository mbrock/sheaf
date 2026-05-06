defmodule DatalabTest do
  use ExUnit.Case, async: false

  setup do
    Req.Test.verify_on_exit!()
  end

  test "starts a Datalab pipeline job for a PDF" do
    path = Path.join(System.tmp_dir!(), "sheaf-pdf-test.pdf")
    File.write!(path, "%PDF-1.7\n")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/pipelines/pl_test/run"

      body = IO.iodata_to_binary(Req.Test.raw_body(conn))
      assert body =~ ~s(name="file")
      assert body =~ ~s(filename="sheaf-pdf-test.pdf")
      assert body =~ ~s(name="output_format")
      assert body =~ "markdown"
      assert body =~ ~s(name="page_range")
      assert body =~ "16-18"

      Req.Test.json(conn, %{
        "execution_id" => "pex_test",
        "status" => "running"
      })
    end)

    assert {:ok, %{"execution_id" => "pex_test", "status" => "running"}} =
             Datalab.start_job(path,
               api_key: "secret",
               pipeline_id: "pl_test",
               page_range: "16-18",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "checks a Datalab pipeline execution" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/pipelines/executions/pex_test"

      Req.Test.json(conn, %{
        "execution_id" => "pex_test",
        "status" => "completed"
      })
    end)

    assert {:ok, %{"execution_id" => "pex_test", "status" => "completed"}} =
             Datalab.check_job("pex_test",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "lists Datalab pipeline executions" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/pipelines/pl_test/executions"
      assert conn.query_params["limit"] == "50"
      assert conn.query_params["offset"] == "100"

      Req.Test.json(conn, %{
        "executions" => [
          %{"execution_id" => "pex_test", "status" => "running"}
        ],
        "total" => 101
      })
    end)

    assert {:ok,
            %{
              "executions" => [%{"execution_id" => "pex_test"}],
              "total" => 101
            }} =
             Datalab.list_pipeline_executions(
               api_key: "secret",
               pipeline_id: "pl_test",
               limit: 50,
               offset: 100,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "fetches markdown from a completed job result" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/api/v1/pipelines/executions/pex_test/steps/0/result"

      Req.Test.json(conn, %{"markdown" => "# Converted\n"})
    end)

    assert {:ok, "# Converted\n"} =
             Datalab.markdown("pex_test",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "converts a PDF to a JSON file" do
    path = Path.join(System.tmp_dir!(), "sheaf-pdf-test.pdf")

    output_path =
      Path.join(System.tmp_dir!(), "sheaf-pdf-test.datalab.hq.json")

    File.write!(path, "%PDF-1.7\n")
    File.rm(output_path)

    Req.Test.expect(__MODULE__, 3, fn conn ->
      case conn.request_path do
        "/api/v1/pipelines/pl_test/run" ->
          body = IO.iodata_to_binary(Req.Test.raw_body(conn))
          assert body =~ "json"

          Req.Test.json(conn, %{
            "execution_id" => "pex_test",
            "status" => "running"
          })

        "/api/v1/pipelines/executions/pex_test" ->
          Req.Test.json(conn, %{
            "execution_id" => "pex_test",
            "status" => "completed"
          })

        "/api/v1/pipelines/executions/pex_test/steps/0/result" ->
          Req.Test.json(conn, %{
            "children" => [%{"block_type" => "Page", "children" => []}],
            "metadata" => %{"title" => "Converted"}
          })
      end
    end)

    assert {:ok,
            %{
              execution_id: "pex_test",
              output_format: "json",
              output_path: ^output_path
            }} =
             Datalab.convert_file(path,
               api_key: "secret",
               output_format: "json",
               output_suffix: "datalab.hq",
               pipeline_id: "pl_test",
               poll_interval: 0,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert %{"metadata" => %{"title" => "Converted"}} =
             output_path
             |> File.read!()
             |> Jason.decode!()
  end

  test "returns a useful error when the API key is missing" do
    previous = Application.get_env(:sheaf, Datalab)
    Application.put_env(:sheaf, Datalab, api_key: nil)

    try do
      assert {:error, :missing_datalab_api_key} =
               Datalab.check_job("pex_test")
    after
      if previous do
        Application.put_env(:sheaf, Datalab, previous)
      else
        Application.delete_env(:sheaf, Datalab)
      end
    end
  end
end
