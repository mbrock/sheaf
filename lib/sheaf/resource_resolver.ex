defmodule Sheaf.ResourceResolver do
  @moduledoc """
  Resolves short Sheaf ids to the resource UI that should handle them.
  """

  alias RDF.Graph
  alias Sheaf.{Corpus, Id}
  alias Sheaf.NS.DOC

  require OpenTelemetry.Tracer, as: Tracer

  @document_types [
    DOC.Document,
    DOC.Paper,
    DOC.Thesis,
    DOC.Transcript,
    DOC.Spreadsheet,
    DOC.GitRepository
  ]

  @type resolution ::
          {:ok, %{kind: :document, id: String.t()}}
          | {:ok, %{kind: :research_note, id: String.t()}}
          | {:ok, %{kind: :software_project, id: String.t()}}
          | {:ok, %{kind: :assistant_conversation, id: String.t()}}
          | {:ok, %{kind: :spreadsheet_query_result, id: String.t()}}
          | {:ok, %{kind: :block, id: String.t(), document_id: String.t()}}
          | {:error, :not_found}

  @spec resolve(String.t()) :: resolution()
  def resolve(id, opts \\ [])

  def resolve(id, opts) when is_binary(id) do
    Tracer.with_span "Sheaf.ResourceResolver.resolve", %{kind: :internal} do
      id = String.trim(id)
      skip_block? = Keyword.get(opts, :skip_block?, false)

      Tracer.set_attribute("sheaf.resource_id", id)
      Tracer.set_attribute("sheaf.skip_block_lookup", skip_block?)

      resolution =
        cond do
          id == "" ->
            {:error, :not_found}

          assistant_conversation?(id) ->
            {:ok, %{kind: :assistant_conversation, id: id}}

          spreadsheet_query_result?(id) ->
            {:ok, %{kind: :spreadsheet_query_result, id: id}}

          research_note?(id) ->
            {:ok, %{kind: :research_note, id: id}}

          software_project?(id) ->
            {:ok, %{kind: :software_project, id: id}}

          document?(id) ->
            {:ok, %{kind: :document, id: id}}

          document_id = block_document_id(id, skip_block?) ->
            {:ok, %{kind: :block, id: id, document_id: document_id}}

          true ->
            {:error, :not_found}
        end

      Tracer.set_attribute("sheaf.resource_kind", resolution_kind(resolution))
      resolution
    end
  end

  def resolve(_id, _opts), do: {:error, :not_found}

  defp resolution_kind({:ok, %{kind: kind}}), do: to_string(kind)
  defp resolution_kind({:error, reason}), do: "error:#{reason}"

  defp document?(id) do
    root = Id.iri(id)

    case Corpus.graph(id) do
      {:ok, %Graph{} = graph} ->
        document_graph?(graph) and document_type?(root, graph)

      _error ->
        false
    end
  end

  defp document_graph?(%Graph{} = graph),
    do: RDF.Data.statement_count(graph) > 0

  defp document_type?(root, %Graph{} = graph) do
    Enum.any?(document_type_iris(), fn type ->
      RDF.Data.include?(graph, {root, RDF.type(), type}) or
        metadata_type?(root, type)
    end)
  end

  defp metadata_type?(root, type) do
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    with :ok <- Sheaf.Repo.load_once({root, RDF.type(), type, metadata_graph}) do
      Sheaf.Repo.ask(fn dataset ->
        case RDF.Dataset.graph(dataset, metadata_graph) do
          %Graph{} = graph ->
            RDF.Data.include?(graph, {root, RDF.type(), type})

          _other ->
            false
        end
      end)
    else
      _error -> false
    end
  end

  defp document_type_iris, do: Enum.map(@document_types, &RDF.iri/1)

  defp block_document_id(_id, true), do: nil
  defp block_document_id(id, false), do: Corpus.find_document(id)

  defp assistant_conversation?(id) do
    workspace_resource?(id, DOC.AssistantConversation)
  end

  defp spreadsheet_query_result?(id) do
    workspace_resource?(id, DOC.SpreadsheetQueryResult) or
      workspace_resource?(id, DOC.QueryResult)
  end

  defp research_note?(id) do
    workspace_resource?(id, DOC.ResearchNote)
  end

  defp software_project?(id) do
    workspace_resource?(id, DOC.SoftwareProject)
  end

  defp workspace_resource?(id, type) do
    iri = Id.iri(id)
    workspace = RDF.iri(Sheaf.Workspace.graph())

    with :ok <- Sheaf.Repo.load_once({iri, nil, nil, workspace}) do
      Sheaf.Repo.ask(fn dataset ->
        case RDF.Dataset.graph(dataset, workspace) do
          %Graph{} = graph ->
            RDF.Data.include?(graph, {iri, RDF.type(), type})

          _other ->
            false
        end
      end)
    else
      _error -> false
    end
  end
end
