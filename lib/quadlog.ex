defmodule Quadlog do
  use GenServer

  def start_link(path, opts \\ []), do: GenServer.start_link(__MODULE__, {path, opts})
  def dataset(pid), do: GenServer.call(pid, :dataset)
  def ask(pid, fun), do: GenServer.call(pid, {:ask, fun})
  def load_graphs(pid, graphs), do: GenServer.call(pid, {:load_graphs, graphs})
  def assert(pid, tx, graph), do: transact(pid, tx, [{:assert, graph}])
  def retract(pid, tx, graph), do: transact(pid, tx, [{:retract, graph}])
  def transact(pid, tx, changes), do: GenServer.call(pid, {:transact, tx, changes})

  @impl true
  def init({path, opts}) do
    with {:ok, conn} <- Exqlite.start_link(database: path),
         :ok <- migrate(conn),
         {:ok, dataset} <- load(conn, Keyword.get(opts, :graphs, :all)) do
      {:ok, %{conn: conn, dataset: dataset}}
    end
  end

  @impl true
  def handle_call(:dataset, _from, state), do: {:reply, state.dataset, state}
  def handle_call({:ask, fun}, _from, state), do: {:reply, fun.(state.dataset), state}

  def handle_call({:load_graphs, graphs}, _from, state) do
    with {:ok, dataset} <- load(state.conn, graphs) do
      graph_names = graph_names(graphs)

      dataset =
        state.dataset
        |> RDF.Dataset.delete_graph(graph_names)
        |> RDF.Dataset.add(dataset)

      {:reply, :ok, %{state | dataset: dataset}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:transact, tx, changes_or_fun}, _from, state) do
    changes =
      if is_function(changes_or_fun, 1) do
        changes_or_fun.(state.dataset)
      else
        changes_or_fun
      end

    rows = sqlite_rows(tx, changes)

    case DBConnection.transaction(state.conn, fn conn -> insert_rows(conn, rows) end) do
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

  defp load(conn, :all) do
    case Exqlite.query(conn, select_sql("ORDER BY seq")) do
      {:ok, result} -> {:ok, apply_sqlite_result(RDF.dataset(), result.rows)}
      error -> error
    end
  end

  defp load(conn, graphs) do
    graph_values = graph_values(graphs)
    named_graphs = Enum.reject(graph_values, &is_nil/1)

    cond do
      graph_values == [] ->
        {:ok, RDF.dataset()}

      named_graphs == [] ->
        select_graphs(conn, "graph_iri IS NULL", [])

      nil in graph_values ->
        placeholders = named_graphs |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
        select_graphs(conn, "graph_iri IS NULL OR graph_iri IN (#{placeholders})", named_graphs)

      true ->
        placeholders = named_graphs |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
        select_graphs(conn, "graph_iri IN (#{placeholders})", named_graphs)
    end
  end

  defp select_graphs(conn, where, params) do
    case Exqlite.query(conn, select_sql("WHERE #{where} ORDER BY seq"), params) do
      {:ok, result} -> {:ok, apply_sqlite_result(RDF.dataset(), result.rows)}
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
        tx,
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

  defp insert_rows(conn, rows), do: Enum.each(rows, &insert_row(conn, &1))

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

  defp graph_values(graphs) when is_list(graphs), do: Enum.map(graphs, &value/1)
  defp graph_values(graph), do: [value(graph)]

  defp graph_names(graphs) do
    Enum.map(graph_values(graphs), fn
      nil -> nil
      graph_iri -> RDF.iri(graph_iri)
    end)
  end

  defp execute(conn, sql, params \\ []) do
    case Exqlite.query(conn, sql, params) do
      {:ok, _result} -> :ok
      error -> error
    end
  end
end
