defmodule Quadlog do
  use GenServer

  require OpenTelemetry.Tracer, as: Tracer

  def start_link(path, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :otel_ctx, &:otel_ctx.get_current/0)
    GenServer.start_link(__MODULE__, {path, opts}, Keyword.take(opts, [:name]))
  end

  def dataset(pid), do: GenServer.call(pid, :dataset)
  def ask(pid, fun), do: GenServer.call(pid, {:ask, :otel_ctx.get_current(), fun})
  def load(pid, pattern), do: GenServer.call(pid, {:load, :otel_ctx.get_current(), pattern})

  def load_once(pid, pattern),
    do: GenServer.call(pid, {:load_once, :otel_ctx.get_current(), pattern})

  def clear_cache(pid), do: GenServer.call(pid, {:clear_cache, :otel_ctx.get_current()})
  def assert(pid, tx, graph), do: transact(pid, tx, [{:assert, graph}])
  def retract(pid, tx, graph), do: transact(pid, tx, [{:retract, graph}])

  def transact(pid, tx, changes),
    do: GenServer.call(pid, {:transact, :otel_ctx.get_current(), tx, changes})

  @impl true
  def init({path, opts}) do
    with_context(Keyword.fetch!(opts, :otel_ctx), fn ->
      with {:ok, conn} <- Exqlite.start_link(database: path),
           :ok <- migrate(conn),
           pattern = load_pattern(opts),
           {:ok, dataset} <- load(conn, pattern, RDF.dataset()) do
        {:ok, %{conn: conn, dataset: dataset, loaded_patterns: MapSet.new([pattern])}}
      end
    end)
  end

  @impl true
  def handle_call(:dataset, _from, state), do: {:reply, state.dataset, state}

  def handle_call({:ask, ctx, fun}, _from, state) do
    with_context(ctx, fn -> {:reply, fun.(state.dataset), state} end)
  end

  def handle_call({:clear_cache, ctx}, _from, state) do
    with_context(ctx, fn ->
      {:reply, :ok, %{state | dataset: RDF.dataset(), loaded_patterns: MapSet.new()}}
    end)
  end

  def handle_call({:load, ctx, pattern}, _from, state) do
    with_context(ctx, fn ->
      load_reply(pattern, state)
    end)
  end

  def handle_call({:load_once, ctx, pattern}, _from, state) do
    with_context(ctx, fn ->
      if MapSet.member?(state.loaded_patterns, pattern) do
        {:reply, :ok, state}
      else
        load_reply(pattern, state)
      end
    end)
  end

  def handle_call({:transact, ctx, tx, changes_or_fun}, _from, state) do
    with_context(ctx, fn ->
      transact_reply(tx, changes_or_fun, state)
    end)
  end

  defp load_reply(pattern, state) do
    with {:ok, dataset} <- load(state.conn, pattern, state.dataset) do
      {:reply, :ok,
       %{state | dataset: dataset, loaded_patterns: MapSet.put(state.loaded_patterns, pattern)}}
    else
      error -> {:reply, error, state}
    end
  end

  defp transact_reply(tx, changes_or_fun, state) do
    changes =
      if is_function(changes_or_fun, 1) do
        changes_or_fun.(state.dataset)
      else
        changes_or_fun
      end

    rows = sqlite_rows(tx, changes)

    case Exqlite.transaction(
           state.conn,
           fn conn ->
             with :ok <- insert_rows(conn, rows), do: apply_quad_rows(conn, rows)
           end,
           timeout: :infinity
         ) do
      {:ok, :ok} ->
        dataset =
          Enum.reduce(changes, state.dataset, fn
            {:assert, graph}, dataset -> RDF.Dataset.add(dataset, graph)
            {:retract, graph}, dataset -> RDF.Dataset.delete(dataset, graph)
          end)

        {:reply, :ok, %{state | dataset: dataset}}

      error ->
        {:reply, error, state}
    end
  end

  defp with_context(ctx, fun) do
    token = :otel_ctx.attach(ctx)

    try do
      fun.()
    after
      :otel_ctx.detach(token)
    end
  end

  defp migrate(conn) do
    with :ok <-
           execute(conn, """
           CREATE TABLE IF NOT EXISTS changes (
             seq INTEGER PRIMARY KEY AUTOINCREMENT,
             tx TEXT NOT NULL,
             polarity INTEGER NOT NULL CHECK (polarity IN (-1, 1)),
             graph_iri TEXT,
             subject_iri TEXT,
             subject_bnode TEXT,
             predicate_iri TEXT NOT NULL,
             object_iri TEXT,
             object_bnode TEXT,
             object_text TEXT,
             object_datatype TEXT,
             object_lang TEXT
           )
           """),
         :ok <-
           execute(conn, """
           CREATE TABLE IF NOT EXISTS terms (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             kind TEXT NOT NULL CHECK (kind IN ('iri', 'bnode', 'literal')),
             value TEXT NOT NULL,
             datatype_id INTEGER REFERENCES terms(id),
             lang TEXT
           )
           """),
         :ok <-
           execute(conn, """
           CREATE UNIQUE INDEX IF NOT EXISTS terms_identity
           ON terms (kind, value, COALESCE(datatype_id, 0), COALESCE(lang, ''))
           """),
         :ok <-
           execute(conn, """
           CREATE INDEX IF NOT EXISTS terms_kind_value
           ON terms (kind, value)
           """),
         :ok <-
           execute(conn, """
           CREATE TABLE IF NOT EXISTS quads (
             graph_id INTEGER NOT NULL DEFAULT 0,
             subject_id INTEGER NOT NULL REFERENCES terms(id),
             predicate_id INTEGER NOT NULL REFERENCES terms(id),
             object_id INTEGER NOT NULL REFERENCES terms(id)
           )
           """),
         :ok <-
           execute(conn, """
           CREATE UNIQUE INDEX IF NOT EXISTS quads_identity
           ON quads (graph_id, subject_id, predicate_id, object_id)
           """),
         :ok <-
           execute(
             conn,
             "CREATE INDEX IF NOT EXISTS quads_spog ON quads (subject_id, predicate_id, object_id, graph_id)"
           ),
         :ok <-
           execute(
             conn,
             "CREATE INDEX IF NOT EXISTS quads_posg ON quads (predicate_id, object_id, subject_id, graph_id)"
           ),
         :ok <-
           execute(
             conn,
             "CREATE INDEX IF NOT EXISTS quads_gspo ON quads (graph_id, subject_id, predicate_id, object_id)"
           ),
         :ok <-
           execute(
             conn,
             "CREATE INDEX IF NOT EXISTS quads_gpos ON quads (graph_id, predicate_id, object_id, subject_id)"
           ) do
      :ok
    end
  end

  defp load(conn, {subject, predicate, object, graph}, dataset) do
    with {:ok, {where, params}} <-
           quad_filters(conn, [
             {"q.subject_id", subject},
             {"q.predicate_id", predicate},
             {"q.object_id", object},
             {"q.graph_id", graph}
           ]),
         {:ok, result} <- select(conn, quad_select_sql(where), params) do
      {:ok, add_quad_result(dataset, result.rows)}
    end
  end

  defp quad_select_sql(where) do
    suffix =
      case where do
        [] -> ""
        where -> "WHERE #{Enum.join(where, " AND ")}"
      end

    """
    SELECT
      g.kind, g.value, gdt.value, g.lang,
      s.kind, s.value, sdt.value, s.lang,
      p.kind, p.value, pdt.value, p.lang,
      o.kind, o.value, odt.value, o.lang
    FROM quads q
    LEFT JOIN terms g ON q.graph_id = g.id
    LEFT JOIN terms gdt ON g.datatype_id = gdt.id
    JOIN terms s ON q.subject_id = s.id
    LEFT JOIN terms sdt ON s.datatype_id = sdt.id
    JOIN terms p ON q.predicate_id = p.id
    LEFT JOIN terms pdt ON p.datatype_id = pdt.id
    JOIN terms o ON q.object_id = o.id
    LEFT JOIN terms odt ON o.datatype_id = odt.id
    #{suffix}
    ORDER BY q.graph_id, q.subject_id, q.predicate_id, q.object_id
    """
  end

  defp select(conn, sql, params) do
    Tracer.with_span "quadlog.sqlite.select", %{
      kind: :client,
      attributes: [
        {"db.system", "sqlite"},
        {"db.operation", "SELECT"},
        {"db.statement", sql}
      ]
    } do
      result = Exqlite.query(conn, sql, params)

      with {:ok, %{rows: rows}} <- result do
        Tracer.set_attribute("db.response.returned_rows", length(rows))
      end

      result
    end
  end

  defp add_quad_result(dataset, rows) do
    Enum.reduce(rows, dataset, fn row, dataset ->
      [
        graph_kind,
        graph_value,
        graph_datatype,
        graph_lang,
        subject_kind,
        subject_value,
        subject_datatype,
        subject_lang,
        predicate_kind,
        predicate_value,
        predicate_datatype,
        predicate_lang,
        object_kind,
        object_value,
        object_datatype,
        object_lang
      ] = row

      graph =
        RDF.Graph.new(
          {
            term(subject_kind, subject_value, subject_datatype, subject_lang),
            term(predicate_kind, predicate_value, predicate_datatype, predicate_lang),
            term(object_kind, object_value, object_datatype, object_lang)
          },
          name: term(graph_kind, graph_value, graph_datatype, graph_lang)
        )

      RDF.Dataset.add(dataset, graph)
    end)
  end

  defp sqlite_rows(tx, changes) do
    for {type, graph} <- changes,
        polarity = if(type == :assert, do: 1, else: -1),
        description <- RDF.Graph.descriptions(graph),
        {predicate, objects} <- description.predications,
        {object, nil} <- objects do
      subject = description.subject

      {subject_iri, subject_bnode} =
        case subject do
          %RDF.IRI{} -> {value(subject), nil}
          %RDF.BlankNode{} -> {nil, value(subject)}
        end

      {object_iri, object_bnode, object_text, object_datatype, object_lang} =
        case object do
          %RDF.IRI{} ->
            {value(object), nil, nil, nil, nil}

          %RDF.BlankNode{} ->
            {nil, value(object), nil, nil, nil}

          %RDF.Literal{} ->
            {nil, nil, RDF.Literal.lexical(object), value(RDF.Literal.datatype_id(object)),
             RDF.Literal.language(object)}
        end

      [
        value(tx),
        polarity,
        value(graph.name),
        subject_iri,
        subject_bnode,
        value(predicate),
        object_iri,
        object_bnode,
        object_text,
        object_datatype,
        object_lang
      ]
    end
  end

  defp insert_rows(conn, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case insert_row(conn, row) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp insert_row(conn, row) do
    execute(
      conn,
      """
      INSERT INTO changes
        (tx, polarity, graph_iri, subject_iri, subject_bnode, predicate_iri,
         object_iri, object_bnode, object_text, object_datatype, object_lang)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      row
    )
  end

  defp apply_quad_rows(conn, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case apply_quad_row(conn, row) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_quad_row(conn, row) do
    {polarity, graph, subject, predicate, object} = row_quad(row)

    with {:ok, graph_id} <- term_id(conn, graph),
         {:ok, subject_id} <- term_id(conn, subject),
         {:ok, predicate_id} <- term_id(conn, predicate),
         {:ok, object_id} <- term_id(conn, object) do
      case polarity do
        1 ->
          execute(
            conn,
            """
            INSERT OR IGNORE INTO quads
              (graph_id, subject_id, predicate_id, object_id)
            VALUES (?, ?, ?, ?)
            """,
            [graph_id, subject_id, predicate_id, object_id]
          )

        -1 ->
          execute(
            conn,
            """
            DELETE FROM quads
            WHERE graph_id = ? AND subject_id = ? AND predicate_id = ? AND object_id = ?
            """,
            [graph_id, subject_id, predicate_id, object_id]
          )
      end
    end
  end

  defp row_quad([
         _tx,
         polarity,
         graph_iri,
         subject_iri,
         subject_bnode,
         predicate_iri,
         object_iri,
         object_bnode,
         object_text,
         object_datatype,
         object_lang
       ]) do
    subject =
      cond do
        subject_iri -> RDF.iri(subject_iri)
        subject_bnode -> RDF.bnode(subject_bnode)
      end

    object =
      cond do
        object_iri -> RDF.iri(object_iri)
        object_bnode -> RDF.bnode(object_bnode)
        object_lang -> RDF.literal(object_text, language: object_lang)
        object_text -> RDF.literal(object_text, datatype: RDF.iri(object_datatype))
      end

    {polarity, if(graph_iri, do: RDF.iri(graph_iri)), subject, RDF.iri(predicate_iri), object}
  end

  defp quad_filters(conn, slots) do
    slots
    |> Enum.reduce_while({:ok, [], []}, fn
      {_column, nil}, {:ok, where, params} ->
        {:cont, {:ok, where, params}}

      {column, term}, {:ok, where, params} ->
        case find_term_id(conn, term) do
          {:ok, nil} -> {:halt, {:ok, ["0 = 1"], []}}
          {:ok, id} -> {:cont, {:ok, ["#{column} = ?" | where], [id | params]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, where, params} -> {:ok, {Enum.reverse(where), Enum.reverse(params)}}
      error -> error
    end
  end

  defp term_id(_conn, nil), do: {:ok, 0}

  defp term_id(conn, %RDF.IRI{} = term), do: intern_term(conn, "iri", value(term), nil, nil)

  defp term_id(conn, %RDF.BlankNode{} = term),
    do: intern_term(conn, "bnode", value(term), nil, nil)

  defp term_id(conn, %RDF.Literal{} = term) do
    with {:ok, datatype_id} <- term_id(conn, RDF.Literal.datatype_id(term)) do
      intern_term(
        conn,
        "literal",
        RDF.Literal.lexical(term),
        datatype_id,
        RDF.Literal.language(term)
      )
    end
  end

  defp find_term_id(conn, %RDF.IRI{} = term), do: find_term_id(conn, "iri", value(term), nil, nil)

  defp find_term_id(conn, %RDF.BlankNode{} = term),
    do: find_term_id(conn, "bnode", value(term), nil, nil)

  defp find_term_id(conn, %RDF.Literal{} = term) do
    with {:ok, datatype_id} when is_integer(datatype_id) <-
           find_term_id(conn, RDF.Literal.datatype_id(term)) do
      find_term_id(
        conn,
        "literal",
        RDF.Literal.lexical(term),
        datatype_id,
        RDF.Literal.language(term)
      )
    else
      {:ok, nil} -> {:ok, nil}
      error -> error
    end
  end

  defp intern_term(conn, kind, value, datatype_id, lang) do
    with :ok <-
           execute(
             conn,
             """
             INSERT OR IGNORE INTO terms (kind, value, datatype_id, lang)
             VALUES (?, ?, ?, ?)
             """,
             [kind, value, datatype_id, lang]
           ) do
      find_term_id(conn, kind, value, datatype_id, lang)
    end
  end

  defp find_term_id(conn, kind, value, datatype_id, lang) do
    with {:ok, result} <-
           select(
             conn,
             """
             SELECT id
             FROM terms
             WHERE kind = ?
               AND value = ?
               AND COALESCE(datatype_id, 0) = ?
               AND COALESCE(lang, '') = ?
             LIMIT 1
             """,
             [kind, value, datatype_id || 0, lang || ""]
           ) do
      case result.rows do
        [[id]] -> {:ok, id}
        [] -> {:ok, nil}
      end
    end
  end

  defp term(nil, nil, nil, nil), do: nil
  defp term("iri", value, _datatype, _lang), do: RDF.iri(value)
  defp term("bnode", value, _datatype, _lang), do: RDF.bnode(value)

  defp term("literal", value, _datatype, lang) when is_binary(lang),
    do: RDF.literal(value, language: lang)

  defp term("literal", value, datatype, _lang),
    do: RDF.literal(value, datatype: RDF.iri(datatype))

  defp value(nil), do: nil
  defp value(term), do: RDF.Term.value(term) |> to_string()

  defp load_pattern(opts), do: Keyword.get(opts, :pattern, {nil, nil, nil, nil})

  defp execute(conn, sql, params \\ []) do
    case Exqlite.query(conn, sql, params) do
      {:ok, _result} -> :ok
      error -> error
    end
  end
end
