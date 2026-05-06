defmodule Sheaf.Document.LaTeX do
  @moduledoc """
  Renders Sheaf document graphs as a compact XeLaTeX source document.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Description
  alias RDF.Graph
  alias Sheaf.Document
  alias Sheaf.NS.{DCTERMS, DOC, FABIO, FOAF}
  alias RDF.NS.RDFS

  @section_commands ~w(chapter section subsection subsubsection paragraph subparagraph)

  @doc """
  Fetches a Sheaf document graph and renders it as LaTeX.
  """
  def render(document_iri, opts \\ []) do
    document_iri = RDF.iri(document_iri)

    Tracer.with_span "Sheaf.Document.LaTeX.render", %{
      kind: :internal,
      attributes: [
        {"sheaf.document", to_string(document_iri)}
      ]
    } do
      with {:ok, graph} <- Sheaf.fetch_graph(document_iri) do
        {:ok, render(graph, document_iri, opts)}
      end
    end
  end

  @doc """
  Renders an already fetched document graph as LaTeX.
  """
  def render(%Graph{} = graph, root, opts) do
    Tracer.with_span "Sheaf.Document.LaTeX.render_graph", %{
      kind: :internal,
      attributes: [
        {"sheaf.document", to_string(root)},
        {"sheaf.document.kind", to_string(Document.kind(graph, root))},
        {"sheaf.statement_count", RDF.Data.statement_count(graph)}
      ]
    } do
      metadata = Keyword.get(opts, :metadata_graph) || fetch_metadata_graph()
      front_matter = front_matter(metadata, root)

      title =
        Keyword.get(opts, :title) || front_matter.title ||
          Document.title(graph, root)

      author = Keyword.get(opts, :author) || front_matter.author || ""

      body =
        graph
        |> Document.children(root)
        |> render_blocks(graph, 0)

      Tracer.set_attribute("sheaf.latex.bytes", IO.iodata_length(body))

      [
        preamble(title, author),
        "\n\\begin{document}\n",
        title_page(title, author, front_matter),
        "\\tableofcontents\n\\clearpage\n\n",
        body,
        "\n\\end{document}\n"
      ]
      |> IO.iodata_to_binary()
    end
  end

  defp fetch_metadata_graph do
    case Sheaf.fetch_graph(Sheaf.Repo.metadata_graph()) do
      {:ok, %Graph{} = graph} -> graph
      _error -> nil
    end
  end

  defp front_matter(nil, _root), do: empty_front_matter()

  defp front_matter(%Graph{} = metadata, root) do
    expression =
      metadata |> Graph.description(root) |> first(FABIO.isRepresentationOf())

    author_names = names(metadata, expression, DCTERMS.creator())
    supervisor_names = names(metadata, expression, DOC.academicSupervisor())

    %{
      title:
        first(metadata, expression, DCTERMS.title()) ||
          first(metadata, expression, RDFS.label()) ||
          first(metadata, root, DCTERMS.title()) ||
          first(metadata, root, RDFS.label()),
      author: Enum.join(author_names, ", "),
      institution:
        resource_name(
          metadata,
          first_resource(metadata, expression, DOC.awardingInstitution())
        ),
      academic_unit:
        resource_name(
          metadata,
          first_resource(metadata, expression, DOC.academicUnit())
        ),
      degree_text: first(metadata, expression, DOC.thesisDegreeText()),
      supervisors: supervisor_names,
      place: first(metadata, expression, DOC.submissionPlace()),
      year: first(metadata, expression, FABIO.hasPublicationYear()),
      declaration: first(metadata, expression, DOC.authorshipDeclaration()),
      declaration_date: first(metadata, expression, DOC.declarationDate())
    }
  end

  defp empty_front_matter do
    %{
      title: nil,
      author: "",
      institution: nil,
      academic_unit: nil,
      degree_text: nil,
      supervisors: [],
      place: nil,
      year: nil,
      declaration: nil,
      declaration_date: nil
    }
  end

  defp names(metadata, subject, predicate) do
    metadata
    |> resources(subject, predicate)
    |> Enum.map(&resource_name(metadata, &1))
    |> Enum.reject(&blank?/1)
  end

  defp first(_graph, nil, _predicate), do: nil

  defp first(%Graph{} = graph, subject, predicate) do
    graph
    |> Graph.description(subject)
    |> first(predicate)
  end

  defp first(nil, _predicate), do: nil

  defp first(%Description{} = description, predicate) do
    case Description.first(description, predicate) do
      nil -> nil
      term -> term |> RDF.Term.value() |> to_string()
    end
  end

  defp first_resource(_graph, nil, _predicate), do: nil

  defp first_resource(%Graph{} = graph, subject, predicate) do
    graph
    |> Graph.description(subject)
    |> Description.first(predicate)
  end

  defp resources(_graph, nil, _predicate), do: []

  defp resources(%Graph{} = graph, subject, predicate) do
    graph
    |> Graph.description(subject)
    |> Description.get(predicate, [])
  end

  defp resource_name(_metadata, nil), do: nil

  defp resource_name(metadata, resource) do
    first(metadata, resource, FOAF.name()) ||
      first(metadata, resource, RDFS.label())
  end

  defp preamble(title, author) do
    [
      "\\documentclass[12pt,a4paper,oneside]{report}\n",
      "\\usepackage{fontspec}\n",
      times_new_roman_fontspec(),
      "\\usepackage{polyglossia}\n",
      "\\setmainlanguage{english}\n",
      "\\setotherlanguage{estonian}\n",
      "\\usepackage[a4paper,top=2.5cm,bottom=2.5cm,left=3.5cm,right=2cm]{geometry}\n",
      "\\usepackage{setspace}\n",
      "\\onehalfspacing\n",
      "\\setlength{\\parindent}{1.27cm}\n",
      "\\usepackage{microtype}\n",
      "\\usepackage{csquotes}\n",
      "\\usepackage{etoolbox}\n",
      "\\usepackage{titlesec}\n",
      "\\titleformat{\\chapter}[hang]{\\normalfont\\Large\\bfseries}{\\thechapter}{1em}{}\n",
      "\\titlespacing*{\\chapter}{0pt}{0pt}{20pt}\n",
      "\\AtBeginEnvironment{quote}{\\singlespacing\\small}\n",
      "\\AtBeginEnvironment{quotation}{\\singlespacing\\small}\n",
      "\\usepackage[hidelinks,pdftitle={",
      latex_escape(title),
      "},pdfauthor={",
      latex_escape(author),
      "}]{hyperref}\n",
      "\\emergencystretch=3em\n",
      "\\title{",
      latex_escape(title),
      "}\n",
      "\\author{",
      latex_escape(author),
      "}\n",
      "\\date{}\n"
    ]
  end

  defp times_new_roman_fontspec do
    font_dir =
      :sheaf
      |> :code.priv_dir()
      |> Path.join("static/fonts")
      |> Path.expand()
      |> String.replace("\\", "/")

    [
      "\\IfFileExists{",
      font_dir,
      "/Times New Roman.ttf}{%\n",
      "  \\setmainfont{Times New Roman}[\n",
      "    Path={",
      font_dir,
      "/},\n",
      "    UprightFont={Times New Roman.ttf},\n",
      "    BoldFont={Times New Roman Bold.ttf},\n",
      "    ItalicFont={Times New Roman Italic.ttf},\n",
      "    BoldItalicFont={Times New Roman Bold Italic.ttf}\n",
      "  ]\n",
      "}{%\n",
      "  \\IfFontExistsTF{Times New Roman}{\\setmainfont{Times New Roman}}{\\setmainfont{TeX Gyre Termes}}\n",
      "}\n"
    ]
  end

  defp title_page(title, author, front_matter) do
    if thesis_front_matter?(front_matter) do
      thesis_title_page(title, author, front_matter)
    else
      simple_title_page(title, author)
    end
  end

  defp thesis_front_matter?(front_matter) do
    not blank?(front_matter.institution) or
      not blank?(front_matter.academic_unit) or
      not blank?(front_matter.degree_text) or front_matter.supervisors != [] or
      not blank?(front_matter.declaration)
  end

  defp simple_title_page(title, "") do
    [
      "\\begin{titlepage}\n",
      "\\thispagestyle{empty}\n",
      "\\begin{center}\n",
      "\\vspace*{5cm}\n",
      "{\\Large\\bfseries ",
      latex_escape(title),
      "}\\\\[1.5em]\n",
      "\\end{center}\n",
      "\\vfill\n",
      "\\end{titlepage}\n",
      "\\setcounter{page}{2}\n"
    ]
  end

  defp simple_title_page(title, author) do
    [
      "\\begin{titlepage}\n",
      "\\thispagestyle{empty}\n",
      "\\begin{center}\n",
      "\\vspace*{4cm}\n",
      "{\\large ",
      latex_escape(author),
      "}\\\\[2cm]\n",
      "{\\Large\\bfseries ",
      latex_escape(title),
      "}\\\\[1.5em]\n",
      "\\end{center}\n",
      "\\vfill\n",
      "\\end{titlepage}\n",
      "\\setcounter{page}{2}\n"
    ]
  end

  defp thesis_title_page(title, author, front_matter) do
    [
      "\\begin{titlepage}\n",
      "\\thispagestyle{empty}\n",
      "\\begin{center}\n",
      optional_line(front_matter.institution, "{\\large ", "\\par}\n"),
      optional_line(front_matter.academic_unit, "{\\large ", "\\par}\n"),
      "\\vspace*{4cm}\n",
      optional_line(author, "{\\large ", "\\par}\n"),
      "\\vspace{2cm}\n",
      "{\\Large\\bfseries ",
      latex_escape(title),
      "\\par}\n",
      "\\vspace{2cm}\n",
      optional_line(front_matter.degree_text, "{\\large ", "\\par}\n"),
      "\\vfill\n",
      supervisor_lines(front_matter.supervisors),
      "\\vspace{1.5cm}\n",
      place_year(front_matter.place, front_matter.year),
      "\\end{center}\n",
      declaration_block(
        author,
        front_matter.declaration,
        front_matter.declaration_date
      ),
      "\\setcounter{page}{2}\n"
    ]
  end

  defp supervisor_lines([]), do: []

  defp supervisor_lines(supervisors) do
    [
      "{\\large ",
      if(length(supervisors) == 1, do: "Supervisor: ", else: "Supervisors: "),
      latex_escape(Enum.join(supervisors, " and ")),
      "\\par}\n"
    ]
  end

  defp place_year(place, year) do
    [place, year]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> []
      parts -> ["{\\large ", latex_escape(Enum.join(parts, " ")), "\\par}\n"]
    end
  end

  defp declaration_block(_author, nil, _date), do: "\\end{titlepage}\n"
  defp declaration_block(_author, "", _date), do: "\\end{titlepage}\n"

  defp declaration_block(author, declaration, date) do
    [
      "\\end{titlepage}\n",
      "\\thispagestyle{empty}\n",
      "\\vspace*{4cm}\n",
      "\\noindent ",
      latex_escape(declaration),
      "\n\n",
      "\\vspace{2cm}\n",
      "\\noindent\\rule{6cm}{0.4pt}\\\\\n",
      latex_escape(signature_line(author, date)),
      "\n\\clearpage\n"
    ]
  end

  defp signature_line("", date),
    do: Enum.reject(["Signature", date], &blank?/1) |> Enum.join(", ")

  defp signature_line(author, date),
    do: Enum.reject([author, date], &blank?/1) |> Enum.join(" ")

  defp optional_line(value, _before, _after) when value in [nil, ""], do: []

  defp optional_line(value, before, after_),
    do: [before, latex_escape(value), after_]

  defp render_blocks(blocks, graph, depth) do
    blocks
    |> Enum.map(&render_block(&1, graph, depth))
    |> Enum.intersperse("\n")
  end

  defp render_block(iri, graph, depth) do
    case Document.block_type(graph, iri) do
      :section ->
        [
          section_command(depth),
          "{",
          latex_escape(Document.heading(graph, iri)),
          "}\n\n",
          graph |> Document.children(iri) |> render_blocks(graph, depth + 1)
        ]

      :paragraph ->
        render_paragraph(graph, iri)

      :extracted ->
        render_extracted(graph, iri)

      :row ->
        [latex_escape(Document.text(graph, iri)), "\n\n"]

      _other ->
        []
    end
  end

  defp section_command(depth) do
    command =
      Enum.at(@section_commands, min(depth, length(@section_commands) - 1))

    "\\#{command}"
  end

  defp render_paragraph(graph, iri) do
    footnotes = Document.footnotes(graph, iri)

    text =
      case Document.paragraph_markup(graph, iri) do
        nil -> latex_escape(Document.paragraph_text(graph, iri))
        markup -> latex_inline(markup, footnotes)
      end

    [text, "\n\n"]
  end

  defp render_extracted(graph, iri) do
    text =
      graph
      |> Document.source_html(iri)
      |> html_text()
      |> latex_escape()

    case Document.source_block_type(graph, iri) do
      "Text" -> [text, "\n\n"]
      _other -> ["\\begin{quote}\\small\n", text, "\n\\end{quote}\n\n"]
    end
  end

  defp latex_inline(markup, footnotes) do
    {markup, tokens} = replace_footnote_markers(markup, footnotes)

    markup
    |> then(
      &Regex.split(~r/<[^>]*>/, &1, include_captures: true, trim: false)
    )
    |> Enum.map_join(&latex_inline_part/1)
    |> restore_tokens(tokens)
  end

  defp replace_footnote_markers(markup, footnotes) do
    footnotes_by_marker =
      Map.new(footnotes, fn footnote ->
        {footnote_marker(footnote), footnote}
      end)

    Regex.scan(~r/<span data-footnote="([^"]+)">.*?<\/span>/, markup)
    |> Enum.with_index()
    |> Enum.reduce({markup, %{}}, fn {[match, marker], index},
                                     {text, tokens} ->
      token = "SHEAF_LATEX_TOKEN_#{index}"
      footnote = Map.get(footnotes_by_marker, marker)

      latex =
        if footnote,
          do: render_footnote(footnote),
          else: "\\textsuperscript{#{latex_escape(marker)}}"

      {String.replace(text, match, token, global: false),
       Map.put(tokens, token, latex)}
    end)
  end

  defp render_footnote(%{markup: markup}) when is_binary(markup) do
    "\\footnote{#{latex_inline(markup, [])}}"
  end

  defp render_footnote(%{text: text}) do
    "\\footnote{#{latex_escape(text)}}"
  end

  defp footnote_marker(%{source_key: source_key, id: id}) do
    case Regex.run(~r/#([^#]+)$/, source_key || "") do
      [_match, marker] -> marker
      _other -> id
    end
  end

  defp latex_inline_part("<strong>"), do: "\\textbf{"
  defp latex_inline_part("</strong>"), do: "}"
  defp latex_inline_part("<b>"), do: "\\textbf{"
  defp latex_inline_part("</b>"), do: "}"
  defp latex_inline_part("<em>"), do: "\\emph{"
  defp latex_inline_part("</em>"), do: "}"
  defp latex_inline_part("<i>"), do: "\\emph{"
  defp latex_inline_part("</i>"), do: "}"
  defp latex_inline_part("<code>"), do: "\\texttt{"
  defp latex_inline_part("</code>"), do: "}"
  defp latex_inline_part("<sup>"), do: "\\textsuperscript{"
  defp latex_inline_part("</sup>"), do: "}"
  defp latex_inline_part("<sub>"), do: "\\textsubscript{"
  defp latex_inline_part("</sub>"), do: "}"
  defp latex_inline_part("<br>"), do: "\\\\{}"
  defp latex_inline_part("<" <> _tag), do: ""
  defp latex_inline_part(text), do: text |> html_entities() |> latex_escape()

  defp restore_tokens(text, tokens) do
    Enum.reduce(tokens, text, fn {token, latex}, text ->
      text
      |> String.replace(token, latex)
      |> String.replace(latex_escape(token), latex)
    end)
  end

  defp html_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p\s*>/i, "\n\n")
    |> String.replace(~r/<[^>]*>/, " ")
    |> html_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end

  defp latex_escape(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\textbackslash{}")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace("$", "\\$")
    |> String.replace("&", "\\&")
    |> String.replace("#", "\\#")
    |> String.replace("_", "\\_")
    |> String.replace("%", "\\%")
    |> String.replace("~", "\\textasciitilde{}")
    |> String.replace("^", "\\textasciicircum{}")
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
