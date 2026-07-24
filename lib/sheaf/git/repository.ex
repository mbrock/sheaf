defmodule Sheaf.Git.Repository do
  @moduledoc """
  Reads Git's reachable object graph without assigning language-specific meaning.

  Git remains authoritative for object payloads. The snapshot returned here
  contains immutable object metadata and topology, mutable references, and
  bounded UTF-8 text fragments from blobs present at `HEAD`.
  """

  require OpenTelemetry.Tracer, as: Tracer

  defmodule Snapshot do
    @moduledoc false

    defstruct [
      :root,
      :git_dir,
      :identity,
      :remote_url,
      :object_format,
      :head,
      :label,
      objects: %{},
      commits: %{},
      trees: %{},
      refs: [],
      fragments: []
    ]
  end

  defmodule Error do
    defexception [:message]
  end

  @default_max_text_bytes 512_000
  @default_max_chunk_bytes 8_000
  @default_max_chunk_lines 120
  @default_concurrency 8

  @text_extensions MapSet.new(~w[
    .adoc .bash .c .cc .cfg .clj .cljs .cmake .cpp .css .csv .cxx .edn
    .el .erl .ex .exs .fish .fs .fsx .go .gql .graphql .h .heex .hh .hpp
    .hrl .hs .htm .html .hxx .in .ini .java .js .json .jsonc .jsx .kt
    .kts .less .lhs .lua .m .markdown .md .metal .mjs .ml .mli .mm .nix
    .org .plist .properties .py .rb .rs .rst .scss .sh .sql .swift .tex
    .toml .ts .tsx .txt .vim .xml .yaml .yml .zig .zsh
  ])

  @text_basenames MapSet.new(~w[
    AGENTS.md Brewfile CMakeLists.txt CODEOWNERS Dockerfile Gemfile Justfile
    LICENSE Makefile Procfile README Rakefile SConstruct Vagrantfile
    WORKSPACE
  ])

  @language_by_extension %{
    ".adoc" => "AsciiDoc",
    ".c" => "C",
    ".cc" => "C++",
    ".cmake" => "CMake",
    ".cpp" => "C++",
    ".cxx" => "C++",
    ".ex" => "Elixir",
    ".exs" => "Elixir",
    ".fish" => "Fish",
    ".go" => "Go",
    ".h" => "C or C++",
    ".heex" => "HEEx",
    ".hh" => "C++",
    ".hpp" => "C++",
    ".hxx" => "C++",
    ".java" => "Java",
    ".js" => "JavaScript",
    ".json" => "JSON",
    ".jsx" => "JavaScript",
    ".kt" => "Kotlin",
    ".kts" => "Kotlin",
    ".lua" => "Lua",
    ".m" => "Objective-C",
    ".markdown" => "Markdown",
    ".md" => "Markdown",
    ".metal" => "Metal",
    ".mjs" => "JavaScript",
    ".ml" => "OCaml",
    ".mli" => "OCaml",
    ".mm" => "Objective-C++",
    ".nix" => "Nix",
    ".org" => "Org",
    ".py" => "Python",
    ".rb" => "Ruby",
    ".rs" => "Rust",
    ".rst" => "reStructuredText",
    ".sh" => "Shell",
    ".sql" => "SQL",
    ".swift" => "Swift",
    ".tex" => "TeX",
    ".toml" => "TOML",
    ".ts" => "TypeScript",
    ".tsx" => "TypeScript",
    ".xml" => "XML",
    ".yaml" => "YAML",
    ".yml" => "YAML",
    ".zig" => "Zig",
    ".zsh" => "Zsh"
  }

  @doc """
  Reads a repository snapshot suitable for projection into RDF.

  Text materialization is limited to eligible UTF-8 blobs present at `HEAD`.
  Set `include_text: false` to read only Git topology.
  """
  def snapshot(path, opts \\ []) when is_binary(path) do
    Tracer.with_span "sheaf.git.repository.snapshot", %{
      kind: :internal,
      attributes: [
        {"sheaf.git.path", Path.expand(path)},
        {"sheaf.git.include_text", Keyword.get(opts, :include_text, true)},
        {"sheaf.git.max_text_bytes",
         Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)}
      ]
    } do
      try do
        snapshot = read_snapshot(path, opts)

        Tracer.set_attributes([
          {"sheaf.git.object_count", map_size(snapshot.objects)},
          {"sheaf.git.commit_count", map_size(snapshot.commits)},
          {"sheaf.git.tree_count", map_size(snapshot.trees)},
          {"sheaf.git.reference_count", length(snapshot.refs)},
          {"sheaf.git.text_fragment_count", length(snapshot.fragments)},
          {"sheaf.git.head", snapshot.head || ""}
        ])

        {:ok, snapshot}
      rescue
        error in Error -> {:error, error.message}
      end
    end
  end

  defp read_snapshot(path, opts) do
    root =
      path
      |> Path.expand()
      |> git!(["rev-parse", "--show-toplevel"])
      |> String.trim()

    git_dir =
      root
      |> git!(["rev-parse", "--absolute-git-dir"])
      |> String.trim()

    object_format =
      root
      |> git!(["rev-parse", "--show-object-format"])
      |> String.trim()

    remote_url =
      root
      |> optional_git(["config", "--get", "remote.origin.url"])
      |> public_remote_url()

    identity =
      Keyword.get_lazy(opts, :identity, fn ->
        repository_identity(remote_url, git_dir)
      end)

    head = optional_git(root, ["rev-parse", "--verify", "HEAD"])
    refs = references(root)
    reachable = reachable_object_ids(root, head)
    objects = reachable_objects(root, reachable)

    commits =
      objects
      |> values_of_type("commit")
      |> parallel_map(&commit(root, &1),
        concurrency: concurrency(opts)
      )
      |> Map.new(&{&1.oid, &1})

    trees =
      objects
      |> values_of_type("tree")
      |> parallel_map(&tree(root, &1),
        concurrency: concurrency(opts)
      )
      |> Map.new(&{&1.oid, &1})

    fragments =
      if Keyword.get(opts, :include_text, true) and is_binary(head) do
        materialized_fragments(root, head, objects, opts)
      else
        []
      end

    %Snapshot{
      root: root,
      git_dir: git_dir,
      identity: identity,
      remote_url: remote_url,
      object_format: object_format,
      head: head,
      label: Keyword.get(opts, :label, Path.basename(root)),
      objects: objects,
      commits: commits,
      trees: trees,
      refs: refs,
      fragments: fragments
    }
  end

  defp repository_identity(remote_url, git_dir) do
    case blank_to_nil(remote_url) do
      nil -> "git-dir:" <> Path.expand(git_dir)
      remote_url -> "remote:" <> remote_url
    end
  end

  defp reachable_object_ids(root, head) do
    head_args = if head, do: [head], else: []

    root
    |> git!([
      "rev-list",
      "--objects",
      "--no-object-names",
      "--branches",
      "--tags",
      "--remotes"
      | head_args
    ])
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end

  defp reachable_objects(root, reachable) do
    root
    |> git!([
      "cat-file",
      "--batch-all-objects",
      "--batch-check=%(objectname)\t%(objecttype)\t%(objectsize)"
    ])
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, objects ->
      case String.split(line, "\t", parts: 3) do
        [oid, type, size] ->
          if MapSet.member?(reachable, oid) do
            Map.put(objects, oid, %{
              oid: oid,
              type: type,
              size: String.to_integer(size)
            })
          else
            objects
          end

        _other ->
          objects
      end
    end)
  end

  defp references(root) do
    root
    |> git!([
      "for-each-ref",
      "--format=%(refname)%09%(objectname)%09%(objecttype)",
      "refs/heads",
      "refs/tags",
      "refs/remotes"
    ])
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [name, oid, type] ->
          %{name: name, oid: oid, type: type}

        _other ->
          raise Error, "could not parse Git reference: #{inspect(line)}"
      end
    end)
  end

  defp commit(root, %{oid: oid}) do
    output =
      git!(root, [
        "show",
        "-s",
        "--format=%H%x00%T%x00%P%x00%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%B",
        oid
      ])

    case :binary.split(output, <<0>>, [:global]) do
      [
        ^oid,
        tree,
        parents,
        author_name,
        author_email,
        authored_at,
        committer_name,
        committer_email,
        committed_at,
        message
      ] ->
        %{
          oid: oid,
          tree: String.trim(tree),
          parents: String.split(parents, " ", trim: true),
          author_name: author_name,
          author_email: author_email,
          authored_at: parse_datetime(authored_at),
          committer_name: committer_name,
          committer_email: committer_email,
          committed_at: parse_datetime(committed_at),
          message: String.trim_trailing(message)
        }

      _other ->
        raise Error, "could not parse Git commit #{oid}"
    end
  end

  defp tree(root, %{oid: oid}) do
    entries =
      root
      |> git!(["ls-tree", "-z", oid])
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_tree_entry(&1, oid))

    %{oid: oid, entries: entries}
  end

  defp parse_tree_entry(record, tree_oid) do
    case :binary.split(record, "\t", [:global]) do
      [header, name] ->
        case String.split(header, " ", parts: 3) do
          [mode, type, oid] ->
            %{tree: tree_oid, name: name, mode: mode, type: type, oid: oid}

          _other ->
            raise Error,
                  "could not parse Git tree entry header: #{inspect(header)}"
        end

      _other ->
        raise Error, "could not parse Git tree entry: #{inspect(record)}"
    end
  end

  defp materialized_fragments(root, head, objects, opts) do
    paths_by_blob =
      root
      |> git!(["ls-tree", "-r", "-z", "--full-tree", head])
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_tree_entry(&1, head))
      |> Enum.filter(&(&1.type == "blob"))
      |> Enum.group_by(& &1.oid, & &1.name)

    candidates =
      paths_by_blob
      |> Enum.flat_map(fn {oid, paths} ->
        case Map.get(objects, oid) do
          %{size: size} = object ->
            eligible_paths = Enum.filter(paths, &text_path?/1)

            if eligible_paths != [] and
                 size <=
                   Keyword.get(
                     opts,
                     :max_text_bytes,
                     @default_max_text_bytes
                   ) do
              [%{object: object, paths: Enum.sort(eligible_paths)}]
            else
              []
            end

          nil ->
            []
        end
      end)

    candidates
    |> parallel_map(
      fn %{object: object, paths: paths} ->
        text_fragments(root, object, paths, opts)
      end,
      concurrency: concurrency(opts)
    )
    |> List.flatten()
    |> Enum.sort_by(&{&1.oid, &1.start_line})
  end

  defp text_fragments(root, object, paths, opts) do
    text = git!(root, ["cat-file", "blob", object.oid])

    if String.valid?(text) and not String.contains?(text, <<0>>) do
      text
      |> chunk_text(opts)
      |> Enum.map(fn chunk ->
        Map.merge(chunk, %{
          oid: object.oid,
          paths: paths,
          language: source_language(List.first(paths))
        })
      end)
    else
      []
    end
  end

  @doc false
  def chunk_text(text, opts \\ []) when is_binary(text) do
    max_bytes =
      Keyword.get(opts, :max_chunk_bytes, @default_max_chunk_bytes)

    max_lines =
      Keyword.get(opts, :max_chunk_lines, @default_max_chunk_lines)

    text
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {chunks, current} ->
      candidate = current ++ [{line_number, line}]

      if current != [] and
           (chunk_bytes(candidate) > max_bytes or
              length(candidate) > max_lines) do
        {[finish_chunk(current) | chunks], [{line_number, line}]}
      else
        {chunks, candidate}
      end
    end)
    |> then(fn {chunks, current} ->
      chunks =
        case current do
          [] -> chunks
          current -> [finish_chunk(current) | chunks]
        end

      chunks
      |> Enum.reverse()
      |> Enum.reject(&(&1.text == ""))
    end)
  end

  defp chunk_bytes(lines) do
    lines
    |> Enum.map(fn {_line_number, line} -> byte_size(line) end)
    |> Enum.sum()
    |> Kernel.+(max(length(lines) - 1, 0))
  end

  defp finish_chunk(lines) do
    {start_line, _first} = List.first(lines)
    {end_line, _last} = List.last(lines)

    %{
      start_line: start_line,
      end_line: end_line,
      text: Enum.map_join(lines, "\n", &elem(&1, 1))
    }
  end

  defp text_path?(path) do
    basename = Path.basename(path)
    extension = path |> Path.extname() |> String.downcase()

    MapSet.member?(@text_extensions, extension) or
      MapSet.member?(@text_basenames, basename) or
      (String.starts_with?(basename, ".") and
         basename in [
           ".clang-format",
           ".clangd",
           ".editorconfig",
           ".env.example",
           ".gitattributes",
           ".gitignore"
         ])
  end

  defp source_language(path) do
    extension = path |> Path.extname() |> String.downcase()

    Map.get(@language_by_extension, extension) ||
      case Path.basename(path) do
        "CMakeLists.txt" -> "CMake"
        "Makefile" -> "Make"
        "Dockerfile" -> "Dockerfile"
        _other -> nil
      end
  end

  defp values_of_type(objects, type) do
    objects
    |> Map.values()
    |> Enum.filter(&(&1.type == type))
    |> Enum.sort_by(& &1.oid)
  end

  defp parallel_map(items, fun, opts) do
    items
    |> Task.async_stream(fun,
      max_concurrency: Keyword.fetch!(opts, :concurrency),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        raise Error, "Git reader task exited: #{inspect(reason)}"
    end)
  end

  defp concurrency(opts) do
    Keyword.get(opts, :concurrency, @default_concurrency)
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise Error, "invalid Git timestamp: #{inspect(reason)}"
    end
  end

  defp optional_git(root, args) do
    case git(root, args) do
      {:ok, output} -> output |> String.trim() |> blank_to_nil()
      {:error, _reason} -> nil
    end
  end

  defp git!(path, args) do
    case git(path, args) do
      {:ok, output} -> output
      {:error, reason} -> raise Error, reason
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error,
         "git #{Enum.join(args, " ")} failed with status #{status}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError ->
      {:error, "could not execute git: #{Exception.message(error)}"}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp public_remote_url(nil), do: nil

  defp public_remote_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, userinfo: userinfo} = uri
      when is_binary(scheme) and is_binary(userinfo) ->
        uri |> Map.put(:userinfo, nil) |> URI.to_string()

      _uri ->
        value
    end
  end
end
