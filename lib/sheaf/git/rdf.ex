defmodule Sheaf.Git.RDF do
  @moduledoc """
  Deterministic RDF identities and projections for Git repository snapshots.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.Git.Repository.Snapshot
  alias Sheaf.NS.DOC

  @doc """
  Returns the deterministic Sheaf IRI for a Git object.
  """
  def object_iri(object_format, oid) do
    deterministic_iri(["git", "objects", object_format, oid])
  end

  @doc """
  Returns the deterministic Sheaf IRI for one entry in an immutable Git tree.
  """
  def tree_entry_iri(object_format, tree_oid, name) do
    encoded_name = Base.url_encode64(name, padding: false)

    deterministic_iri([
      "git",
      "tree-entries",
      object_format,
      tree_oid,
      encoded_name
    ])
  end

  @doc """
  Returns the repository-scoped IRI for a mutable Git reference.
  """
  def reference_iri(repository_iri, name) do
    suffix = Base.url_encode64(name, padding: false)
    RDF.iri(to_string(repository_iri) <> "/refs/" <> suffix)
  end

  @doc """
  Returns the deterministic IRI for a text fragment of an immutable blob.
  """
  def fragment_iri(object_format, blob_oid, start_line, end_line) do
    deterministic_iri([
      "git",
      "fragments",
      object_format,
      blob_oid,
      "#{start_line}-#{end_line}"
    ])
  end

  @doc """
  Builds the append-only immutable portion of a repository projection.

  `known_object_ids` allows synchronization to avoid reasserting facts already
  stored in Quadlog's change log.
  """
  def object_graph(
        %Snapshot{} = snapshot,
        repository_iri,
        known_object_ids \\ MapSet.new()
      ) do
    graph = Graph.new(name: repository_iri)

    snapshot.objects
    |> Map.values()
    |> Enum.reject(&MapSet.member?(known_object_ids, &1.oid))
    |> Enum.sort_by(& &1.oid)
    |> Enum.reduce(graph, fn object, graph ->
      add_object(graph, snapshot, repository_iri, object)
    end)
  end

  @doc """
  Builds the replaceable graph of searchable text at the current `HEAD`.
  """
  def text_graph(%Snapshot{} = snapshot, repository_iri, graph_name) do
    Enum.reduce(snapshot.fragments, Graph.new(name: graph_name), fn fragment,
                                                                    graph ->
      add_fragment(graph, snapshot, repository_iri, fragment)
    end)
  end

  @doc """
  Builds the replaceable graph of current Git references.
  """
  def references_graph(%Snapshot{} = snapshot, repository_iri, graph_name) do
    graph = Graph.new(name: graph_name)

    graph =
      if snapshot.head do
        Graph.add(
          graph,
          {repository_iri, DOC.gitHead(),
           object_iri(snapshot.object_format, snapshot.head)}
        )
      else
        graph
      end

    Enum.reduce(snapshot.refs, graph, fn ref, graph ->
      reference = reference_iri(repository_iri, ref.name)
      target = object_iri(snapshot.object_format, ref.oid)

      graph
      |> Graph.add({repository_iri, DOC.hasGitReference(), reference})
      |> Graph.add({reference, RDF.type(), DOC.GitReference})
      |> Graph.add({reference, RDFS.label(), ref.name})
      |> Graph.add({reference, DOC.gitReferenceName(), ref.name})
      |> Graph.add({reference, DOC.pointsToGitObject(), target})
      |> Graph.add({reference, DOC.inGitRepository(), repository_iri})
    end)
  end

  defp add_object(graph, snapshot, repository_iri, object) do
    iri = object_iri(snapshot.object_format, object.oid)

    graph
    |> Graph.add({iri, RDF.type(), DOC.GitObject})
    |> Graph.add({iri, RDF.type(), object_class(object.type)})
    |> Graph.add({iri, RDFS.label(), object_label(object)})
    |> Graph.add({iri, DOC.gitObjectId(), object.oid})
    |> Graph.add({iri, DOC.byteSize(), object.size})
    |> Graph.add({iri, DOC.inGitRepository(), repository_iri})
    |> add_object_details(snapshot, repository_iri, object)
  end

  defp add_object_details(
         graph,
         snapshot,
         _repository_iri,
         %{type: "commit", oid: oid}
       ) do
    case Map.fetch(snapshot.commits, oid) do
      {:ok, commit} ->
        commit_iri = object_iri(snapshot.object_format, oid)

        graph
        |> Graph.add(
          {commit_iri, DOC.hasRootTree(),
           object_iri(snapshot.object_format, commit.tree)}
        )
        |> add_each(commit.parents, fn parent ->
          {commit_iri, DOC.hasParentCommit(),
           object_iri(snapshot.object_format, parent)}
        end)
        |> add_optional(commit_iri, DOC.authorName(), commit.author_name)
        |> add_optional(commit_iri, DOC.authorEmail(), commit.author_email)
        |> add_optional(commit_iri, DOC.authoredAt(), commit.authored_at)
        |> add_optional(
          commit_iri,
          DOC.committerName(),
          commit.committer_name
        )
        |> add_optional(
          commit_iri,
          DOC.committerEmail(),
          commit.committer_email
        )
        |> add_optional(commit_iri, DOC.committedAt(), commit.committed_at)
        |> add_optional(commit_iri, DOC.commitMessage(), commit.message)

      :error ->
        graph
    end
  end

  defp add_object_details(
         graph,
         snapshot,
         repository_iri,
         %{type: "tree", oid: oid}
       ) do
    case Map.fetch(snapshot.trees, oid) do
      {:ok, tree} ->
        tree_iri = object_iri(snapshot.object_format, oid)

        Enum.reduce(tree.entries, graph, fn entry, graph ->
          entry_iri =
            tree_entry_iri(snapshot.object_format, oid, entry.name)

          graph
          |> Graph.add({tree_iri, DOC.hasGitTreeEntry(), entry_iri})
          |> Graph.add({entry_iri, RDF.type(), DOC.GitTreeEntry})
          |> Graph.add({entry_iri, RDFS.label(), safe_text(entry.name)})
          |> Graph.add({entry_iri, DOC.gitEntryName(), safe_text(entry.name)})
          |> Graph.add({entry_iri, DOC.gitFileMode(), entry.mode})
          |> Graph.add(
            {entry_iri, DOC.pointsToGitObject(),
             object_iri(snapshot.object_format, entry.oid)}
          )
          |> Graph.add({entry_iri, DOC.inGitRepository(), repository_iri})
        end)

      :error ->
        graph
    end
  end

  defp add_object_details(graph, _snapshot, _repository_iri, _object),
    do: graph

  defp add_fragment(graph, snapshot, repository_iri, fragment) do
    blob_iri = object_iri(snapshot.object_format, fragment.oid)

    fragment_iri =
      fragment_iri(
        snapshot.object_format,
        fragment.oid,
        fragment.start_line,
        fragment.end_line
      )

    graph
    |> Graph.add({fragment_iri, RDF.type(), DOC.GitTextFragment})
    |> Graph.add(
      {fragment_iri, RDFS.label(),
       fragment_label(fragment.paths, fragment.start_line, fragment.end_line)}
    )
    |> Graph.add({fragment_iri, DOC.inGitBlob(), blob_iri})
    |> Graph.add({fragment_iri, DOC.inGitRepository(), repository_iri})
    |> Graph.add({fragment_iri, DOC.startLine(), fragment.start_line})
    |> Graph.add({fragment_iri, DOC.endLine(), fragment.end_line})
    |> Graph.add({fragment_iri, DOC.text(), fragment.text})
    |> add_optional(fragment_iri, DOC.sourceLanguage(), fragment.language)
    |> add_each(fragment.paths, fn path ->
      {fragment_iri, DOC.sourcePath(), path}
    end)
    |> add_blob_content_metadata(blob_iri, fragment)
  end

  defp add_blob_content_metadata(graph, blob_iri, fragment) do
    path = List.first(fragment.paths)

    graph
    |> add_optional(blob_iri, DOC.sourceLanguage(), fragment.language)
    |> add_optional(blob_iri, DOC.mimeType(), mime_type(path))
  end

  defp add_each(graph, values, statement) do
    Enum.reduce(values, graph, fn value, graph ->
      Graph.add(graph, statement.(value))
    end)
  end

  defp add_optional(graph, _subject, _predicate, value)
       when value in [nil, ""],
       do: graph

  defp add_optional(graph, subject, predicate, value),
    do: Graph.add(graph, {subject, predicate, value})

  defp object_class("commit"), do: DOC.GitCommit
  defp object_class("tree"), do: DOC.GitTree
  defp object_class("blob"), do: DOC.GitBlob
  defp object_class("tag"), do: DOC.GitTag
  defp object_class(_other), do: DOC.GitObject

  defp object_label(%{type: type, oid: oid}) do
    "Git #{type} #{String.slice(oid, 0, 12)}"
  end

  defp fragment_label([path | _paths], start_line, end_line),
    do: "#{path}:#{start_line}-#{end_line}"

  defp fragment_label([], start_line, end_line),
    do: "Git text lines #{start_line}-#{end_line}"

  defp mime_type(nil), do: nil
  defp mime_type(path), do: MIME.from_path(path)

  defp safe_text(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: "base64:" <> Base.encode64(value)
  end

  defp deterministic_iri(parts) do
    suffix = Enum.join(parts, "/")
    RDF.iri(Sheaf.Id.base_iri() <> suffix)
  end
end
