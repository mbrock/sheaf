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
  Returns the stable repository-scoped IRI for a current source file.
  """
  def source_file_iri(repository_iri, path) do
    suffix = Base.url_encode64(path, padding: false)
    RDF.iri(to_string(repository_iri) <> "/source-files/" <> suffix)
  end

  @doc """
  Returns the stable repository-scoped IRI for a current source directory.
  """
  def source_directory_iri(repository_iri, path) do
    suffix = Base.url_encode64(path, padding: false)
    RDF.iri(to_string(repository_iri) <> "/source-directories/" <> suffix)
  end

  @doc """
  Returns the fragment IRI for the single complete-content block of a source
  file.
  """
  def source_file_block_iri(source_file_iri) do
    RDF.iri(to_string(source_file_iri) <> "#content")
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
    directories = source_directories(snapshot.source_files)

    Graph.new(name: graph_name)
    |> Graph.add({repository_iri, RDF.type(), DOC.Document})
    |> Graph.add({repository_iri, RDF.type(), DOC.GitRepository})
    |> Graph.add({repository_iri, RDFS.label(), snapshot.label})
    |> add_source_directories(repository_iri, directories)
    |> add_source_files(snapshot, repository_iri)
    |> add_source_children(repository_iri, directories, snapshot.source_files)
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

  defp add_source_file(graph, snapshot, repository_iri, source_file) do
    blob_iri = object_iri(snapshot.object_format, source_file.oid)
    source_file_iri = source_file_iri(repository_iri, source_file.path)
    block_iri = source_file_block_iri(source_file_iri)

    graph
    |> Graph.add({source_file_iri, RDF.type(), DOC.GitSourceFile})
    |> Graph.add({source_file_iri, RDFS.label(), source_file.path})
    |> Graph.add({source_file_iri, DOC.sourcePath(), source_file.path})
    |> Graph.add({source_file_iri, DOC.inGitRepository(), repository_iri})
    |> Graph.add(
      {source_file_iri, DOC.atGitCommit(),
       object_iri(snapshot.object_format, snapshot.head)}
    )
    |> Graph.add({source_file_iri, DOC.hasGitBlob(), blob_iri})
    |> Graph.add({source_file_iri, DOC.hasSourceFileBlock(), block_iri})
    |> add_children(source_file_iri, [block_iri])
    |> add_optional(
      source_file_iri,
      DOC.sourceLanguage(),
      source_file.language
    )
    |> Graph.add({block_iri, RDF.type(), DOC.SourceFileBlock})
    |> Graph.add({block_iri, RDFS.label(), "#{source_file.path} content"})
    |> Graph.add({block_iri, DOC.inSourceFile(), source_file_iri})
    |> Graph.add({block_iri, DOC.inGitBlob(), blob_iri})
    |> Graph.add({block_iri, DOC.text(), source_file.text})
    |> add_blob_content_metadata(blob_iri, source_file)
  end

  defp source_directories(source_files) do
    source_files
    |> Enum.flat_map(fn source_file ->
      source_file.path
      |> Path.dirname()
      |> directory_ancestors()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp directory_ancestors("."), do: []

  defp directory_ancestors(path) do
    parts = Path.split(path)

    1..length(parts)
    |> Enum.map(fn count -> parts |> Enum.take(count) |> Path.join() end)
  end

  defp add_source_directories(graph, repository_iri, directories) do
    Enum.reduce(directories, graph, fn path, graph ->
      directory = source_directory_iri(repository_iri, path)

      graph
      |> Graph.add({directory, RDF.type(), DOC.GitSourceDirectory})
      |> Graph.add({directory, RDFS.label(), Path.basename(path)})
      |> Graph.add({directory, DOC.sourcePath(), path})
      |> Graph.add({directory, DOC.inGitRepository(), repository_iri})
    end)
  end

  defp add_source_files(graph, snapshot, repository_iri) do
    Enum.reduce(snapshot.source_files, graph, fn source_file, graph ->
      add_source_file(graph, snapshot, repository_iri, source_file)
    end)
  end

  defp add_source_children(
         graph,
         repository_iri,
         directories,
         source_files
       ) do
    parents = [nil | directories]

    Enum.reduce(parents, graph, fn parent_path, graph ->
      parent =
        if parent_path,
          do: source_directory_iri(repository_iri, parent_path),
          else: repository_iri

      child_directories =
        directories
        |> Enum.filter(&(parent_directory(&1) == parent_path))
        |> Enum.map(&source_directory_iri(repository_iri, &1))

      child_files =
        source_files
        |> Enum.filter(&(parent_directory(&1.path) == parent_path))
        |> Enum.sort_by(& &1.path)
        |> Enum.map(&source_file_iri(repository_iri, &1.path))

      add_children(graph, parent, child_directories ++ child_files)
    end)
  end

  defp parent_directory(path) do
    case Path.dirname(path) do
      "." -> nil
      parent -> parent
    end
  end

  defp add_children(graph, parent, []) do
    Graph.add(graph, {parent, DOC.children(), RDF.NS.RDF.nil()})
  end

  defp add_children(graph, parent, children) do
    list_nodes =
      Enum.with_index(children, fn _child, index ->
        suffix = if index == 0, do: "#children", else: "#children-#{index}"
        RDF.iri(to_string(parent) <> suffix)
      end)

    graph = Graph.add(graph, {parent, DOC.children(), hd(list_nodes)})

    children
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {child, index}, graph ->
      rest = Enum.at(list_nodes, index + 1) || RDF.NS.RDF.nil()

      graph
      |> Graph.add({Enum.at(list_nodes, index), RDF.first(), child})
      |> Graph.add({Enum.at(list_nodes, index), RDF.rest(), rest})
    end)
  end

  defp add_blob_content_metadata(graph, blob_iri, source_file) do
    graph
    |> add_optional(blob_iri, DOC.sourceLanguage(), source_file.language)
    |> add_optional(blob_iri, DOC.mimeType(), mime_type(source_file.path))
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
