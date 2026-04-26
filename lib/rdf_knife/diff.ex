defmodule RDFKnife.Diff do
  @moduledoc """
  Applies simple RDF dataset patches produced by `rdfknife diff --patch`.

  The patch format is intentionally boring JSON:

      {
        "format": "rdfknife.patch.v1",
        "positive": "...N-Quads to insert...",
        "negative": "...N-Quads to delete..."
      }

  `positive` and `negative` are parsed as ordinary N-Quads datasets and can be
  rendered as SPARQL Update or applied through a caller-provided update function.
  """

  alias RDF.{Dataset, Graph, IRI}

  @format "rdfknife.patch.v1"

  defstruct positive: Dataset.new(), negative: Dataset.new(), metadata: %{}

  @type t :: %__MODULE__{
          positive: Dataset.t(),
          negative: Dataset.t(),
          metadata: map()
        }

  @doc """
  Reads a patch JSON file.
  """
  @spec read_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def read_file(path) do
    path
    |> File.read()
    |> case do
      {:ok, json} -> read_string(json)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads a patch JSON string.
  """
  @spec read_string(String.t()) :: {:ok, t()} | {:error, term()}
  def read_string(json) when is_binary(json) do
    with {:ok, raw} <- Jason.decode(json),
         :ok <- validate_format(raw),
         {:ok, positive} <- parse_nquads(Map.get(raw, "positive", "")),
         {:ok, negative} <- parse_nquads(Map.get(raw, "negative", "")) do
      {:ok,
       %__MODULE__{
         positive: positive,
         negative: negative,
         metadata: Map.drop(raw, ["positive", "negative"])
       }}
    end
  end

  @doc """
  Reads a patch JSON file, raising on errors.
  """
  @spec read_file!(Path.t()) :: t()
  def read_file!(path) do
    case read_file(path) do
      {:ok, diff} -> diff
      {:error, reason} -> raise ArgumentError, "failed to read RDF diff patch: #{inspect(reason)}"
    end
  end

  @doc """
  Returns counts for a patch.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = diff) do
    %{
      format: Map.get(diff.metadata, "format", @format),
      positive: Dataset.statement_count(diff.positive),
      negative: Dataset.statement_count(diff.negative),
      graphs: %{
        positive: graph_summary(diff.positive),
        negative: graph_summary(diff.negative)
      }
    }
  end

  @doc """
  Converts the patch into SPARQL Update text.
  """
  @spec to_sparql(t()) :: {:ok, String.t()} | {:error, term()}
  def to_sparql(%__MODULE__{} = diff) do
    with {:ok, delete_data} <- operation("DELETE DATA", diff.negative),
         {:ok, insert_data} <- operation("INSERT DATA", diff.positive) do
      [delete_data, insert_data]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Converts the patch into SPARQL Update text, raising on errors.
  """
  @spec to_sparql!(t()) :: String.t()
  def to_sparql!(%__MODULE__{} = diff) do
    case to_sparql(diff) do
      {:ok, sparql} -> sparql
      {:error, reason} -> raise ArgumentError, "failed to render RDF diff patch: #{inspect(reason)}"
    end
  end

  @doc """
  Applies a patch through a SPARQL update function or endpoint.

  Options:

    * `:update` - a function receiving one SPARQL Update string. It should return
      `:ok`, `{:ok, term}`, or `{:error, term}`.
    * `:endpoint` - a SPARQL Update endpoint URL. Used when `:update` is absent.
    * `:auth` - optional Req auth option for endpoint mode.
    * `:dry_run` - when true, returns the rendered update without executing it.
  """
  @spec apply(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(%__MODULE__{} = diff, opts \\ []) do
    with {:ok, sparql} <- to_sparql(diff) do
      cond do
        Keyword.get(opts, :dry_run, false) ->
          {:ok, %{summary: summary(diff), sparql: sparql, applied?: false}}

        update = Keyword.get(opts, :update) ->
          apply_with_update(diff, sparql, update)

        endpoint = Keyword.get(opts, :endpoint) ->
          apply_with_endpoint(diff, sparql, endpoint, opts)

        true ->
          {:error, :missing_update_target}
      end
    end
  end

  @doc """
  Applies a patch to an in-memory dataset.
  """
  @spec apply_to_dataset(t(), Dataset.t()) :: Dataset.t()
  def apply_to_dataset(%__MODULE__{} = diff, %Dataset{} = dataset) do
    dataset
    |> Dataset.delete(diff.negative)
    |> Dataset.add(diff.positive)
  end

  defp validate_format(%{"format" => @format}), do: :ok
  defp validate_format(%{"format" => other}), do: {:error, {:unsupported_patch_format, other}}
  defp validate_format(_raw), do: {:error, :missing_patch_format}

  defp parse_nquads(nquads) when is_binary(nquads), do: RDF.NQuads.read_string(nquads)
  defp parse_nquads(other), do: {:error, {:invalid_nquads_payload, other}}

  defp operation(verb, %Dataset{} = dataset) do
    if Dataset.empty?(dataset) do
      {:ok, ""}
    else
      with {:ok, graph_blocks} <- graph_blocks(dataset) do
        {:ok, "#{verb} {\n#{graph_blocks}\n}"}
      end
    end
  end

  defp graph_blocks(%Dataset{} = dataset) do
    dataset
    |> Dataset.graphs()
    |> Enum.sort_by(&graph_sort_key/1)
    |> Enum.reduce_while({:ok, []}, fn graph, {:ok, blocks} ->
      case graph_block(graph) do
        {:ok, ""} -> {:cont, {:ok, blocks}}
        {:ok, block} -> {:cont, {:ok, [block | blocks]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, blocks |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp graph_sort_key(%Graph{name: nil}), do: ""
  defp graph_sort_key(%Graph{name: name}), do: to_string(name)

  defp graph_block(%Graph{} = graph) do
    triples = graph |> RDF.NTriples.write_string!() |> String.trim()

    cond do
      triples == "" ->
        {:ok, ""}

      is_nil(graph.name) ->
        {:ok, indent(triples)}

      match?(%IRI{}, graph.name) ->
        {:ok, "  GRAPH #{format_iri(graph.name)} {\n#{indent(triples, 4)}\n  }"}

      true ->
        {:error, {:unsupported_graph_name, graph.name}}
    end
  end

  defp indent(text, spaces \\ 2) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp format_iri(%IRI{} = iri), do: "<#{RDF.IRI.to_string(iri)}>"

  defp graph_summary(%Dataset{} = dataset) do
    dataset
    |> Dataset.graphs()
    |> Enum.map(fn graph ->
      {graph_label(graph.name), Graph.statement_count(graph)}
    end)
    |> Enum.sort_by(fn {graph, _count} -> graph end)
  end

  defp graph_label(nil), do: "(default graph)"
  defp graph_label(graph_name), do: to_string(graph_name)

  defp apply_with_update(diff, sparql, update) when is_function(update, 1) do
    case update.(sparql) do
      :ok -> {:ok, %{summary: summary(diff), applied?: true}}
      {:ok, _result} -> {:ok, %{summary: summary(diff), applied?: true}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_update_result, other}}
    end
  end

  defp apply_with_endpoint(diff, sparql, endpoint, opts) do
    request =
      Req.new(
        url: endpoint,
        auth: Keyword.get(opts, :auth),
        http_errors: :raise
      )

    Req.post!(request, form: [update: sparql])
    {:ok, %{summary: summary(diff), applied?: true}}
  rescue
    exception -> {:error, exception}
  end
end
