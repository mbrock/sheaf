defmodule Docs do
  @moduledoc """
  Small live-node documentation helper for agents and local development.

  It uses the docs and source metadata already available in the running BEAM
  node, so it is fast and version-aligned with the application that is actually
  running.
  """

  @default_source_context 30

  @doc """
  Render an overview or target docs as plain text.

  Targets may be app atoms such as `:rdf`, module names such as `Sheaf.NS`, or
  function names such as `Sheaf.mint/0`. Pass `include_source: true` to include
  short source clips when source files are available.
  """
  def render(targets \\ [], opts \\ []) do
    include_source = Keyword.get(opts, :include_source, false)

    targets
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        overview(:sheaf)

      normalized_targets ->
        normalized_targets
        |> Enum.map(&render_target(&1, include_source))
        |> Enum.join("\n\n---\n\n")
    end
  end

  defp overview(app) when is_atom(app) do
    modules = app_modules(app)
    title = app |> Atom.to_string() |> app_title()

    [
      "# #{title} module overview",
      "",
      "Application: `#{inspect(app)}`",
      "Use `bin/docs Module.Name` or `bin/docs Module.function/arity` for details.",
      "Use `bin/docs :app_name` to list modules for another loaded OTP application.",
      "Use `bin/docs --source Module.function/arity` to include a short source clip.",
      "",
      "#{title} modules",
      hierarchy_lines(modules)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp app_modules(app) when is_atom(app) do
    app
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.sort()
  end

  defp app_title(app_name) when is_binary(app_name) do
    app_name
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp hierarchy_lines(modules) do
    module_names =
      MapSet.new(modules, fn module ->
        module
        |> Atom.to_string()
        |> String.trim_leading("Elixir.")
      end)

    modules
    |> Enum.map(fn module ->
      module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")
      |> String.split(".")
    end)
    |> Enum.reduce(%{}, &put_module_path/2)
    |> render_module_tree([], module_names, 0)
  end

  defp put_module_path([segment], tree) do
    Map.put_new(tree, segment, %{})
  end

  defp put_module_path([segment | rest], tree) do
    Map.update(tree, segment, put_module_path(rest, %{}), &put_module_path(rest, &1))
  end

  defp put_module_path([], tree), do: tree

  defp render_module_tree(tree, prefix, module_names, depth) do
    tree
    |> Enum.sort_by(fn {segment, _children} -> segment end)
    |> Enum.flat_map(fn {segment, children} ->
      path = prefix ++ [segment]
      name = Enum.join(path, ".")

      line = "#{String.duplicate("  ", depth)}- #{name}#{module_summary(name, module_names)}"

      [line | render_module_tree(children, path, module_names, depth + 1)]
    end)
  end

  defp module_summary(name, module_names) do
    if MapSet.member?(module_names, name) do
      name
      |> module_from_name()
      |> module_doc_summary()
      |> case do
        nil -> ""
        summary -> " - #{summary}"
      end
    else
      ""
    end
  end

  defp module_from_name(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end

  defp module_doc_summary(module) when is_atom(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, _, _} ->
        module_doc
        |> doc_text()
        |> first_doc_line()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp module_doc_summary(_), do: nil

  defp first_doc_line(nil), do: nil

  defp first_doc_line(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> List.first()
  end

  defp render_target(target, include_source) do
    case parse_target(target) do
      {:ok, {:module, module}} ->
        render_module(module, target, include_source)

      {:ok, {:function, module, function, arity}} ->
        render_function(module, function, arity, target, include_source)

      {:ok, {:app, app}} ->
        overview(app)

      {:error, reason} ->
        "# #{target}\n\n#{reason}"
    end
  end

  defp render_module(module, requested_as, include_source) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, metadata, fun_docs} ->
        source_path = source_path(module, metadata)
        public_functions = public_functions(fun_docs)

        [
          "# #{inspect(module)}",
          "",
          "Requested as: #{requested_as}",
          "Source: #{source_path || "(unknown)"}",
          "Public functions: #{length(public_functions)}",
          doc_text(module_doc) && "",
          doc_text(module_doc),
          "",
          "Public API",
          Enum.map(public_functions, &"- #{&1.signature || "#{&1.name}/#{&1.arity}"}"),
          include_source && "",
          include_source && source_clip(source_path, 1, @default_source_context)
        ]
        |> List.flatten()
        |> Enum.reject(&(&1 in [nil, false]))
        |> Enum.join("\n")

      {:error, reason} ->
        "# #{inspect(module)}\n\nNo docs available: #{inspect(reason)}"
    end
  end

  defp render_function(module, function, arity, requested_as, include_source) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _module_doc, metadata, fun_docs} ->
        source_path = source_path(module, metadata)
        matches = matching_functions(fun_docs, function, arity)

        case matches do
          [] ->
            "# #{requested_as}\n\nNo matching public function found in #{inspect(module)}."

          functions ->
            functions
            |> Enum.map(&function_text(module, &1, requested_as, source_path, include_source))
            |> Enum.join("\n\n")
        end

      {:error, reason} ->
        "# #{requested_as}\n\nNo docs available for #{inspect(module)}: #{inspect(reason)}"
    end
  end

  defp function_text(module, function, requested_as, source_path, include_source) do
    [
      "# #{inspect(module)}.#{function.name}/#{function.arity}",
      "",
      "Requested as: #{requested_as}",
      function.signature && "Signature: #{function.signature}",
      "Source: #{source_path || "(unknown)"}:#{function.line || 0}",
      function.doc && "",
      function.doc,
      include_source && "",
      include_source && source_clip(source_path, function.line, @default_source_context)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp public_functions(fun_docs) do
    fun_docs
    |> Enum.flat_map(fn
      {{:function, _name, _arity}, _line, _signatures, :hidden, _metadata} ->
        []

      {{:function, name, arity}, line, signatures, docs, _metadata} ->
        [
          %{
            name: Atom.to_string(name),
            arity: arity,
            line: line,
            signature: List.first(signatures),
            doc: doc_text(docs)
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  defp matching_functions(fun_docs, function, nil) do
    fun_docs
    |> public_functions()
    |> Enum.filter(&(&1.name == function))
  end

  defp matching_functions(fun_docs, function, arity) do
    fun_docs
    |> public_functions()
    |> Enum.filter(&(&1.name == function and &1.arity == arity))
  end

  defp parse_target(target) do
    app_pattern = ~r/\A:(?<app>[a-z][a-zA-Z0-9_]*[!?]?)\z/

    module_pattern =
      ~r/\A(?<module>(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\z/

    function_pattern =
      ~r/\A(?<module>(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.(?<function>[a-z_][A-Za-z0-9_!?]*)(?:\/(?<arity>\d+))?\z/

    cond do
      captures = Regex.named_captures(app_pattern, target) ->
        with {:ok, app} <- resolve_app(captures["app"]) do
          {:ok, {:app, app}}
        end

      captures = Regex.named_captures(function_pattern, target) ->
        with {:ok, module} <- resolve_module(captures["module"]) do
          {:ok, {:function, module, captures["function"], parse_arity(captures["arity"])}}
        end

      Regex.match?(module_pattern, target) ->
        with {:ok, module} <- resolve_module(target) do
          {:ok, {:module, module}}
        end

      true ->
        {:error, "Invalid docs target: #{inspect(target)}"}
    end
  end

  defp resolve_module(name) when is_binary(name) do
    name
    |> module_candidates()
    |> Enum.find_value({:error, "Unknown or unloaded module: #{name}"}, fn candidate ->
      try do
        module = String.to_existing_atom(candidate)

        if Code.ensure_loaded?(module), do: {:ok, module}, else: nil
      rescue
        ArgumentError -> nil
      end
    end)
  end

  defp module_candidates("Elixir." <> _ = name), do: [name]
  defp module_candidates(name), do: ["Elixir." <> name, name]

  defp resolve_app(name) when is_binary(name) do
    try do
      app = String.to_existing_atom(name)

      case Application.spec(app, :modules) do
        modules when is_list(modules) -> {:ok, app}
        _ -> {:error, "Unknown loaded OTP application: :#{name}"}
      end
    rescue
      ArgumentError -> {:error, "Unknown loaded OTP application: :#{name}"}
    end
  end

  defp parse_arity(value) when is_binary(value) and value != "" do
    case Integer.parse(value) do
      {arity, ""} when arity >= 0 -> arity
      _ -> nil
    end
  end

  defp parse_arity(_), do: nil

  defp doc_text(%{"en" => text}) when is_binary(text), do: String.trim(text)
  defp doc_text(:none), do: nil
  defp doc_text(_), do: nil

  defp source_path(module, metadata) do
    normalize_path(metadata[:source_path]) || compile_source(module)
  end

  defp compile_source(module) do
    module
    |> module.module_info(:compile)
    |> Keyword.get(:source)
    |> normalize_path()
  rescue
    _ -> nil
  end

  defp normalize_path(path) when is_binary(path), do: path
  defp normalize_path(path) when is_list(path), do: List.to_string(path)
  defp normalize_path(_), do: nil

  defp source_clip(path, line, context)
       when is_binary(path) and is_integer(line) and line > 0 do
    if File.regular?(path) do
      lines = File.read!(path) |> String.split("\n")
      from_line = max(line, 1)
      to_line = min(line + context - 1, length(lines))

      body =
        lines
        |> Enum.slice(from_line - 1, to_line - from_line + 1)
        |> Enum.with_index(from_line)
        |> Enum.map(fn {text, number} -> "#{number}: #{text}" end)
        |> Enum.join("\n")

      ["Source excerpt #{from_line}-#{to_line}:", "```elixir", body, "```"]
      |> Enum.join("\n")
    else
      "(source unavailable)"
    end
  end

  defp source_clip(_path, _line, _context), do: "(source unavailable)"
end
