defmodule Sheaf.ResourceResolver do
  @moduledoc """
  Resolves short Sheaf ids to the resource UI that should handle them.
  """

  alias RDF.Graph
  alias Sheaf.{Corpus, Id}
  alias Sheaf.NS.DOC

  @type resolution ::
          {:ok, %{kind: :document, id: String.t()}}
          | {:ok, %{kind: :assistant_conversation, id: String.t()}}
          | {:ok, %{kind: :spreadsheet_query_result, id: String.t()}}
          | {:ok, %{kind: :block, id: String.t(), document_id: String.t()}}
          | {:error, :not_found}

  @spec resolve(String.t()) :: resolution()
  def resolve(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        {:error, :not_found}

      document?(id) ->
        {:ok, %{kind: :document, id: id}}

      assistant_conversation?(id) ->
        {:ok, %{kind: :assistant_conversation, id: id}}

      spreadsheet_query_result?(id) ->
        {:ok, %{kind: :spreadsheet_query_result, id: id}}

      document_id = Corpus.find_document(id) ->
        {:ok, %{kind: :block, id: id, document_id: document_id}}

      true ->
        {:error, :not_found}
    end
  end

  def resolve(_id), do: {:error, :not_found}

  defp document?(id) do
    root = Id.iri(id)

    case Sheaf.fetch_graph(root) do
      {:ok, %Graph{} = graph} -> RDF.Data.include?(graph, {root, RDF.type(), DOC.Document})
      _error -> false
    end
  end

  defp assistant_conversation?(id) do
    workspace_resource?(id, DOC.AssistantConversation)
  end

  defp spreadsheet_query_result?(id) do
    workspace_resource?(id, DOC.SpreadsheetQueryResult) or
      workspace_resource?(id, DOC.QueryResult)
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
