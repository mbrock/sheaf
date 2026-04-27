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

    case Exqlite.transaction(state.conn, fn conn -> insert_rows(conn, rows) end) do
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
    """)
  end

  defp load(conn, pattern, dataset)

  defp load(conn, {nil, nil, nil, nil}, dataset) do
    sql = select_sql("ORDER BY seq")

    case select(conn, sql) do
      {:ok, result} -> {:ok, apply_sqlite_result(dataset, result.rows)}
      error -> error
    end
  end

  defp load(conn, {subject, predicate, object, graph}, dataset) do
    {where, params} =
      [
        {"subject_iri", subject},
        {"predicate_iri", predicate},
        {"object_iri", object},
        {"graph_iri", graph}
      ]
      |> Enum.reject(fn {_column, term} -> is_nil(term) end)
      |> Enum.map(fn {column, term} -> {"#{column} = ?", value(term)} end)
      |> Enum.unzip()

    suffix =
      case where do
        [] -> "ORDER BY seq"
        where -> "WHERE #{Enum.join(where, " AND ")} ORDER BY seq"
      end

    sql = select_sql(suffix)

    case select(conn, sql, params) do
      {:ok, result} -> {:ok, apply_sqlite_result(dataset, result.rows)}
      error -> error
    end
  end

  defp select_sql(suffix) do
    """
    SELECT tx, polarity, graph_iri, subject_iri, subject_bnode, predicate_iri,
           object_iri, object_bnode, object_text, object_datatype, object_lang
    FROM changes
    #{suffix}
    """
  end

  defp select(conn, sql, params \\ []) do
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

  defp apply_sqlite_result(dataset, rows) do
    Enum.reduce(rows, dataset, fn row, dataset ->
      [
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
      ] = row

      subject =
        cond do
          subject_iri -> %RDF.IRI{value: subject_iri}
          subject_bnode -> %RDF.BlankNode{value: subject_bnode}
        end

      object =
        cond do
          object_iri -> %RDF.IRI{value: object_iri}
          object_bnode -> %RDF.BlankNode{value: object_bnode}
          object_lang -> RDF.literal(object_text, language: object_lang)
          object_text -> RDF.literal(object_text, datatype: RDF.iri(object_datatype))
        end

      graph =
        RDF.Graph.new(
          {subject, %RDF.IRI{value: predicate_iri}, object},
          name: if(graph_iri, do: %RDF.IRI{value: graph_iri})
        )

      case polarity do
        1 -> RDF.Dataset.add(dataset, graph)
        -1 -> RDF.Dataset.delete(dataset, graph)
      end
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
