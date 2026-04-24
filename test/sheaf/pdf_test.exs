defmodule Sheaf.PDFTest do
  use ExUnit.Case, async: false

  alias Sheaf.PDF

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

      Req.Test.json(conn, %{"execution_id" => "pex_test", "status" => "running"})
    end)

    assert {:ok, %{"execution_id" => "pex_test", "status" => "running"}} =
             PDF.start_job(path,
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

      Req.Test.json(conn, %{"execution_id" => "pex_test", "status" => "completed"})
    end)

    assert {:ok, %{"execution_id" => "pex_test", "status" => "completed"}} =
             PDF.check_job("pex_test",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "fetches markdown from a completed job result" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/pipelines/executions/pex_test/steps/0/result"

      Req.Test.json(conn, %{"markdown" => "# Converted\n"})
    end)

    assert {:ok, "# Converted\n"} =
             PDF.markdown("pex_test",
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "converts a PDF to a JSON file" do
    path = Path.join(System.tmp_dir!(), "sheaf-pdf-test.pdf")
    output_path = Path.join(System.tmp_dir!(), "sheaf-pdf-test.datalab.json")
    File.write!(path, "%PDF-1.7\n")
    File.rm(output_path)

    Req.Test.expect(__MODULE__, 3, fn conn ->
      case conn.request_path do
        "/api/v1/pipelines/pl_test/run" ->
          body = IO.iodata_to_binary(Req.Test.raw_body(conn))
          assert body =~ "json"
          Req.Test.json(conn, %{"execution_id" => "pex_test", "status" => "running"})

        "/api/v1/pipelines/executions/pex_test" ->
          Req.Test.json(conn, %{"execution_id" => "pex_test", "status" => "completed"})

        "/api/v1/pipelines/executions/pex_test/steps/0/result" ->
          Req.Test.json(conn, %{
            "children" => [%{"block_type" => "Page", "children" => []}],
            "metadata" => %{"title" => "Converted"}
          })
      end
    end)

    assert {:ok, %{execution_id: "pex_test", output_format: "json", output_path: ^output_path}} =
             PDF.convert_file(path,
               api_key: "secret",
               output_format: "json",
               output_path: output_path,
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
    previous = Application.get_env(:sheaf, PDF)
    Application.put_env(:sheaf, PDF, api_key: nil)

    try do
      assert {:error, :missing_datalab_api_key} = PDF.check_job("pex_test")
    after
      if previous do
        Application.put_env(:sheaf, PDF, previous)
      else
        Application.delete_env(:sheaf, PDF)
      end
    end
  end
end
