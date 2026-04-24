defmodule Sheaf.Assistant.Notes do
  @moduledoc """
  Persistent assistant-authored research notes.

  Notes are stored as RDF facts with ActivityStreams vocabulary for the note
  shape and Sheaf vocabulary for block mentions. The writer appends facts with
  SPARQL `INSERT DATA`; it does not revise or delete older notes.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.BlockRefs
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC, PROV}

  @default_limit 20

  @doc """
  Lists recently published assistant notes.
  """
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    with {:ok, result} <- Sheaf.select(list_query(limit)) do
      {:ok, from_rows(result.results)}
    end
  end

  @doc false
  def from_rows(rows) do
    rows
    |> Enum.group_by(&row_value(&1, "note"))
    |> Enum.reject(fn {note_iri, _rows} -> is_nil(note_iri) end)
    |> Enum.map(fn {_note_iri, rows} -> note_from_rows(rows) end)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  @doc """
  Builds and persists a note.

  Required attrs:

    * `:text` - note body
    * `:agent_iri` or `:agent_id`
    * `:session_iri` or `:session_id`

  Optional attrs:

    * `:block_ids` - explicit mentioned block ids
    * `:title`
    * `:agent_label`
    * `:session_label`

  Options:

    * `:note_iri` - deterministic note IRI for tests/imports
    * `:published_at` - deterministic timestamp
    * `:update` - function called with SPARQL update text
  """
  def write(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, note} <- build(attrs, opts),
         :ok <- persist(note.graph, opts) do
      {:ok, Map.drop(note, [:graph])}
    end
  end

  @doc """
  Builds the note graph without persisting it.
  """
  def build(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, text} <- required_text(attrs),
         {:ok, note_iri} <- note_iri(attrs, opts),
         {:ok, agent_iri} <- required_iri(attrs, :agent),
         {:ok, session_iri} <- required_iri(attrs, :session),
         {:ok, published_at} <- published_at(opts) do
      block_ids = block_ids(attrs, text)

      graph =
        note_triples(note_iri, agent_iri, session_iri, text, published_at, block_ids, attrs)
        |> Graph.new()

      {:ok,
       %{
         id: Id.id_from_iri(note_iri),
         iri: to_string(note_iri),
         agent_id: Id.id_from_iri(agent_iri),
         agent_iri: to_string(agent_iri),
         session_id: Id.id_from_iri(session_iri),
         session_iri: to_string(session_iri),
         text: text,
         title: optional_text(attrs, :title),
         block_ids: block_ids,
         published_at: DateTime.to_iso8601(published_at),
         graph: graph
       }}
    end
  end

  @doc """
  Returns the SPARQL update that appends the note facts to the default graph.
  """
  def insert_data(%Graph{} = graph) do
    triples =
      graph
      |> RDF.NTriples.write_string!()
      |> String.trim()

    """
    INSERT DATA {
    #{indent(triples)}
    }
    """
  end

  defp persist(%Graph{} = graph, opts) do
    update = Keyword.get(opts, :update, &Sheaf.update/1)

    case update.(insert_data(graph)) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_update_result, other}}
    end
  end

  defp list_query(limit) do
    """
    PREFIX as: <https://www.w3.org/ns/activitystreams#>
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    SELECT ?note ?title ?content ?published ?agent ?agentLabel ?context ?contextLabel ?mention WHERE {
      {
        SELECT ?note ?published WHERE {
          ?note a as:Note .
          OPTIONAL { ?note as:published ?published }
        }
        ORDER BY DESC(?published)
        LIMIT #{limit}
      }

      ?note as:content ?content .
      OPTIONAL { ?note rdfs:label ?title }
      OPTIONAL {
        ?note as:attributedTo ?agent .
        OPTIONAL { ?agent rdfs:label ?agentLabel }
      }
      OPTIONAL {
        ?note as:context ?context .
        OPTIONAL { ?context rdfs:label ?contextLabel }
      }
      OPTIONAL { ?note sheaf:mentions ?mention }
    }
    ORDER BY DESC(?published)
    """
  end

  defp note_from_rows([row | _] = rows) do
    note_iri = row_value(row, "note")
    agent_iri = row_value(row, "agent")
    session_iri = row_value(row, "context")

    %{
      id: Id.id_from_iri(note_iri),
      iri: note_iri,
      title: row_value(row, "title"),
      text: row_value(row, "content") || "",
      published_at: row_value(row, "published"),
      agent_id: id_or_nil(agent_iri),
      agent_iri: agent_iri,
      agent_label: row_value(row, "agentLabel"),
      session_id: id_or_nil(session_iri),
      session_iri: session_iri,
      session_label: row_value(row, "contextLabel"),
      mentions: mentions(rows)
    }
  end

  defp mentions(rows) do
    rows
    |> Enum.map(&row_value(&1, "mention"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn iri ->
      id = Id.id_from_iri(iri)
      %{id: id, iri: iri, path: "/b/#{id}"}
    end)
  end

  defp sort_key(%{published_at: %DateTime{} = published_at}), do: DateTime.to_unix(published_at)
  defp sort_key(%{published_at: nil}), do: 0
  defp sort_key(%{published_at: published_at}), do: to_string(published_at)

  defp id_or_nil(nil), do: nil
  defp id_or_nil(iri), do: Id.id_from_iri(iri)

  defp row_value(row, key) do
    row
    |> Map.get(key)
    |> term_value()
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

  defp note_triples(note_iri, agent_iri, session_iri, text, published_at, block_ids, attrs) do
    [
      {note_iri, RDF.type(), AS.Note},
      {note_iri, AS.attributedTo(), agent_iri},
      {note_iri, AS.context(), session_iri},
      {note_iri, AS.published(), published_at},
      {note_iri, AS.content(), text},
      {agent_iri, RDF.type(), PROV.SoftwareAgent},
      {session_iri, RDF.type(), DOC.ResearchSession}
    ]
    |> maybe_add_label(note_iri, optional_text(attrs, :title))
    |> maybe_add_label(agent_iri, optional_text(attrs, :agent_label))
    |> maybe_add_label(session_iri, optional_text(attrs, :session_label))
    |> Kernel.++(Enum.map(block_ids, &{note_iri, DOC.mentions(), Id.iri(&1)}))
  end

  defp maybe_add_label(triples, _iri, nil), do: triples
  defp maybe_add_label(triples, iri, label), do: [{iri, RDFS.label(), label} | triples]

  defp required_text(attrs) do
    case optional_text(attrs, :text) do
      nil -> {:error, "note text is required"}
      text -> {:ok, text}
    end
  end

  defp optional_text(attrs, key) do
    attrs
    |> arg(key)
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end

  defp note_iri(attrs, opts) do
    case Keyword.get(opts, :note_iri) || arg(attrs, :note_iri) || arg(attrs, :note_id) do
      nil -> {:ok, Sheaf.mint()}
      value -> normalize_iri(value, :note)
    end
  end

  defp required_iri(attrs, role) do
    iri_key = :"#{role}_iri"
    id_key = :"#{role}_id"

    case arg(attrs, iri_key) || arg(attrs, id_key) do
      nil -> {:error, "#{role} identity is required"}
      value -> normalize_iri(value, role)
    end
  end

  defp normalize_iri(%RDF.IRI{} = iri, _role), do: {:ok, iri}

  defp normalize_iri(value, role) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "#{role} identity is required"}

      String.starts_with?(value, ["http://", "https://"]) ->
        {:ok, RDF.iri(value)}

      true ->
        {:ok, Id.iri(value)}
    end
  end

  defp normalize_iri(_value, role), do: {:error, "invalid #{role} identity"}

  defp published_at(opts) do
    case Keyword.get(opts, :published_at) do
      nil -> {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}
      %DateTime{} = timestamp -> {:ok, DateTime.truncate(timestamp, :second)}
      _other -> {:error, "published_at must be a DateTime"}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_limit), do: @default_limit

  defp block_ids(attrs, text) do
    explicit =
      attrs
      |> arg(:block_ids)
      |> List.wrap()

    (explicit ++ BlockRefs.ids_from_text(text))
    |> Enum.flat_map(&normalize_block_id/1)
    |> Enum.uniq()
  end

  defp normalize_block_id(%RDF.IRI{} = iri), do: [Id.id_from_iri(iri)]

  defp normalize_block_id(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("#")

    cond do
      value == "" -> []
      String.starts_with?(value, ["http://", "https://"]) -> [Id.id_from_iri(value)]
      true -> [value]
    end
  end

  defp normalize_block_id(_other), do: []

  defp indent(""), do: ""

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp arg(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
