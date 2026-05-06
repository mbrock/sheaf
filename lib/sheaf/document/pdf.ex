defmodule Sheaf.Document.PDF do
  @moduledoc """
  Compiles Sheaf document LaTeX exports to PDF.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Sheaf.Document.LaTeX

  @default_timeout 30_000

  @doc """
  Fetches a document graph, renders it as LaTeX, and compiles it to PDF bytes.
  """
  def render(document_iri, opts \\ []) do
    document_iri = RDF.iri(document_iri)

    Tracer.with_span "Sheaf.Document.PDF.render", %{
      kind: :internal,
      attributes: [
        {"sheaf.document", to_string(document_iri)},
        {"sheaf.pdf.timeout_ms",
         Keyword.get(opts, :timeout, @default_timeout)},
        {"sheaf.pdf.xelatex_runs", xelatex_runs(opts)}
      ]
    } do
      with {:ok, latex} <- LaTeX.render(document_iri, opts),
           {:ok, pdf} <- compile(latex, opts) do
        Tracer.set_attribute("sheaf.pdf.bytes", byte_size(pdf))
        {:ok, pdf}
      end
    end
  end

  @doc false
  def compile(latex, opts \\ []) when is_binary(latex) do
    compiler = Keyword.get_lazy(opts, :compiler, &compiler/0)

    cond do
      not is_binary(compiler) ->
        {:error, :xelatex_not_found}

      true ->
        with_tmp_dir(fn dir ->
          tex_path = Path.join(dir, "document.tex")
          pdf_path = Path.join(dir, "document.pdf")

          with :ok <- File.write(tex_path, latex),
               {:ok, _log} <- run_xelatex_passes(compiler, dir, opts),
               {:ok, pdf} <- File.read(pdf_path) do
            {:ok, pdf}
          end
        end)
    end
  end

  defp compiler do
    Application.get_env(:sheaf, __MODULE__, [])
    |> Keyword.get(:compiler)
    |> case do
      nil -> System.find_executable("xelatex")
      configured -> configured
    end
  end

  defp run_xelatex(compiler, dir, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.async(fn ->
        System.cmd(
          compiler,
          ["-interaction=nonstopmode", "-halt-on-error", "document.tex"],
          cd: dir,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {log, 0}} ->
        {:ok, log}

      {:ok, {log, status}} ->
        {:error, {:xelatex_failed, status, log}}

      nil ->
        {:error, :xelatex_timeout}
    end
  end

  defp run_xelatex_passes(compiler, dir, opts) do
    1..xelatex_runs(opts)
    |> Enum.reduce_while({:ok, []}, fn _run, {:ok, logs} ->
      case run_xelatex(compiler, dir, opts) do
        {:ok, log} -> {:cont, {:ok, [log | logs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, logs} -> {:ok, logs |> Enum.reverse() |> Enum.join("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp xelatex_runs(opts) do
    opts
    |> Keyword.get(:xelatex_runs, 2)
    |> max(1)
  end

  defp with_tmp_dir(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sheaf-latex-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end
