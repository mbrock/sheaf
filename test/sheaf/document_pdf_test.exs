defmodule Sheaf.Document.PDFTest do
  use ExUnit.Case, async: true

  alias Sheaf.Document.PDF

  test "compiles LaTeX source to PDF bytes" do
    if System.find_executable("xelatex") do
      latex = """
      \\documentclass{article}
      \\begin{document}
      Hello Sheaf.
      \\end{document}
      """

      assert {:ok, "%PDF" <> _rest} = PDF.compile(latex, timeout: 10_000)
    end
  end

  test "returns an error when xelatex is unavailable" do
    latex = """
    \\documentclass{article}
    \\begin{document}
    Hello Sheaf.
    \\end{document}
    """

    assert {:error, :xelatex_not_found} = PDF.compile(latex, compiler: nil)
  end

  test "runs xelatex twice so generated tables of contents are populated" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sheaf-pdf-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    compiler = Path.join(dir, "fake-xelatex")
    counter = Path.join(dir, "runs")

    File.write!(compiler, """
    #!/bin/sh
    count=0
    if [ -f "#{counter}" ]; then
      count=$(cat "#{counter}")
    fi
    count=$((count + 1))
    printf "%s" "$count" > "#{counter}"
    printf "%%PDF fake\\n" > document.pdf
    exit 0
    """)

    File.chmod!(compiler, 0o755)

    try do
      latex = """
      \\documentclass{article}
      \\begin{document}
      \\tableofcontents
      \\section{Hello}
      \\end{document}
      """

      assert {:ok, "%PDF fake\n"} = PDF.compile(latex, compiler: compiler)
      assert File.read!(counter) == "2"
    after
      File.rm_rf(dir)
    end
  end
end
