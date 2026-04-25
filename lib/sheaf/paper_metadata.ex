defmodule Sheaf.PaperMetadata do
  @moduledoc """
  Extracts paper metadata from PDFs or extracted document text with `Sheaf.LLM`.

  This is meant to provide a lightweight first pass over local PDFs: enough
  Crossref-facing metadata to search by DOI/title/authors.
  """

  alias RDF.Graph

  @default_text_chars 80_000

  @type t :: %__MODULE__{
          title: String.t() | nil,
          authors: [String.t()],
          doi: String.t() | nil,
          year: String.t() | nil,
          publication: String.t() | nil,
          volume: String.t() | nil,
          issue: String.t() | nil,
          pages: String.t() | nil,
          confidence: String.t() | nil,
          notes: String.t() | nil,
          model: String.t(),
          source_filename: String.t() | nil,
          usage: map() | nil
        }

  defstruct [
    :title,
    :doi,
    :year,
    :publication,
    :volume,
    :issue,
    :pages,
    :confidence,
    :notes,
    :source_filename,
    :usage,
    authors: [],
    model: Sheaf.LLM.default_model()
  ]

  @doc """
  Extracts metadata from a local PDF path.

  Options:

    * LLM request options accepted by `Sheaf.LLM.generate_object/3`.
  """
  @spec extract_pdf(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def extract_pdf(path, opts \\ []) when is_binary(path) do
    with {:ok, pdf} <- File.read(path) do
      extract_pdf_binary(pdf, Path.basename(path), opts)
    end
  end

  @doc """
  Extracts metadata from PDF bytes.
  """
  @spec extract_pdf_binary(binary(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def extract_pdf_binary(pdf, filename, opts \\ [])
      when is_binary(pdf) and is_binary(filename) do
    message =
      Sheaf.LLM.user_message([
        Sheaf.LLM.file_part(pdf, filename, "application/pdf"),
        Sheaf.LLM.text_part(prompt(:pdf))
      ])

    extract_message(message, Keyword.put(opts, :source_filename, filename))
  end

  @doc """
  Extracts metadata from plain document text.

  Use this when Datalab has already produced readable text blocks. By default
  the first 80,000 characters are sent; pass `chars: :all` or `chars: nil` to
  send the full text, or another integer to choose a different slice.
  """
  @spec extract_text(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def extract_text(text, opts \\ []) when is_binary(text) do
    text =
      text
      |> normalize_source_text()
      |> slice_source_text(Keyword.get(opts, :chars, @default_text_chars))

    if text == "" do
      {:error, :empty_text}
    else
      message =
        Sheaf.LLM.user_message([
          Sheaf.LLM.text_part(prompt(:text)),
          Sheaf.LLM.text_part(source_text_part(text))
        ])

      extract_message(message, opts)
    end
  end

  @doc """
  Extracts metadata from a fetched document graph and root document IRI.
  """
  @spec extract_graph(Graph.t(), RDF.IRI.t() | String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def extract_graph(%Graph{} = graph, root, opts \\ []) do
    graph
    |> Sheaf.Document.bibliographic_text(root, opts)
    |> extract_text(opts)
  end

  @doc """
  Fetches a stored document graph by IRI and extracts metadata from its text blocks.
  """
  @spec extract_document(RDF.IRI.t() | String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def extract_document(document_iri, opts \\ []) do
    document_iri = RDF.iri(document_iri)

    with {:ok, text} <- Sheaf.Document.bibliographic_text(document_iri, opts) do
      text
      |> extract_text(opts)
    end
  end

  @doc """
  Bang variant of `extract_pdf/2`.
  """
  @spec extract_pdf!(Path.t(), keyword()) :: t()
  def extract_pdf!(path, opts \\ []) do
    case extract_pdf(path, opts) do
      {:ok, metadata} -> metadata
      {:error, reason} -> raise "failed to extract paper metadata: #{inspect(reason)}"
    end
  end

  @doc false
  def default_model, do: Sheaf.LLM.default_model()

  @doc false
  def prompt, do: prompt(:pdf)

  @doc false
  def prompt(:pdf) do
    """
    Extract basic bibliographic metadata for the attached academic PDF.

    Rules:
    - Prefer information visible in the PDF.
    - Pay special attention to DOI metadata, first-page citation information, headers, and footers.
    - Normalize DOI as lowercase without a leading https://doi.org/.
    - Leave DOI as an empty string if no DOI is visible or strongly inferable from the document itself.
    - If multiple DOIs appear only in references, do not return a reference DOI as the paper DOI.
    - Return only the fields in the schema.
    """
  end

  def prompt(:text) do
    """
    Extract basic bibliographic metadata for the provided academic paper text.

    Rules:
    - Prefer information visible in the provided text.
    - Pay special attention to DOI metadata, first-page citation information, headers, and footers.
    - Normalize DOI as lowercase without a leading https://doi.org/.
    - Leave DOI as an empty string if no DOI is visible or strongly inferable from the document text.
    - If multiple DOIs appear only in references, do not return a reference DOI as the paper DOI.
    - Return only the fields in the schema.
    """
  end

  @doc false
  def schema do
    [
      title: [type: :string, required: true],
      authors: [type: {:list, :string}, required: true],
      doi: [type: :string, required: true],
      year: [type: :string, required: true],
      publication: [type: :string, required: true],
      volume: [type: :string, required: true],
      issue: [type: :string, required: true],
      pages: [type: :string, required: true],
      confidence: [type: :string, required: true],
      notes: [type: :string, required: true]
    ]
  end

  @doc false
  def normalize_object(object, opts \\ []) when is_map(object) do
    %__MODULE__{
      title: string_value(object, :title),
      authors: string_list_value(object, :authors),
      doi: normalize_doi(value(object, :doi)),
      year: string_value(object, :year),
      publication: string_value(object, :publication),
      volume: string_value(object, :volume),
      issue: string_value(object, :issue),
      pages: string_value(object, :pages),
      confidence: string_value(object, :confidence),
      notes: string_value(object, :notes),
      model: Keyword.get(opts, :model, Sheaf.LLM.default_model()),
      source_filename: Keyword.get(opts, :source_filename),
      usage: Keyword.get(opts, :usage)
    }
  end

  defp extract_message(message, opts) do
    case Sheaf.LLM.generate_object(message, schema(), opts) do
      {:ok, result} ->
        {:ok,
         normalize_object(result.object,
           model: result.model,
           source_filename: Keyword.get(opts, :source_filename),
           usage: result.usage
         )}

      {:error, reason} ->
        if reason == :missing_object,
          do: {:error, :missing_metadata_object},
          else: {:error, reason}
    end
  end

  defp source_text_part(text) do
    """
    Document text:

    #{text}
    """
  end

  defp normalize_source_text(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp slice_source_text(text, chars) when chars in [nil, :all], do: text

  defp slice_source_text(text, chars) when is_integer(chars) and chars >= 0 do
    String.slice(text, 0, chars)
  end

  defp slice_source_text(text, _chars), do: text

  defp string_value(object, key), do: object |> value(key) |> string_value()

  defp string_value(nil), do: nil
  defp string_value(""), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(_value), do: nil

  defp string_list_value(object, key) do
    object
    |> value(key)
    |> string_list_value()
  end

  defp string_list_value(values) when is_list(values) do
    values
    |> Enum.map(&string_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp string_list_value(value) do
    case string_value(value) do
      nil -> []
      value -> [value]
    end
  end

  defp value(object, key) when is_map(object) do
    Map.get(object, key) || Map.get(object, Atom.to_string(key))
  end

  defp normalize_doi(nil), do: nil

  defp normalize_doi(value) do
    value
    |> string_value()
    |> case do
      nil ->
        nil

      doi ->
        doi
        |> String.replace(~r/\Ahttps?:\/\/(?:dx\.)?doi\.org\//i, "")
        |> String.replace(~r/\Adoi:\s*/i, "")
        |> String.trim()
        |> String.trim_trailing(".")
        |> String.trim_trailing(",")
        |> String.trim_trailing(";")
        |> String.trim_trailing(":")
        |> String.downcase()
        |> string_value()
    end
  end
end
