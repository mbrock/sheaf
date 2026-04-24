defmodule Sheaf.Assistant.Notes do
  @moduledoc """
  Persistent assistant-authored research notes.

  Notes are stored as RDF facts with ActivityStreams vocabulary for the note
  shape and Sheaf vocabulary for block mentions. The writer appends facts with
  SPARQL `INSERT DATA`; it does not revise or delete older notes.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC, PROV}

  @block_ref_pattern ~r/(?:#|\/b\/)([A-Z0-9]{6})\b/

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

  defp note_triples(note_iri, agent_iri, session_iri, text, published_at, block_ids, attrs) do
    [
      {note_iri, RDF.type(), AS.Note},
      {note_iri, AS.attributed_to(), agent_iri},
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

  defp block_ids(attrs, text) do
    explicit =
      attrs
      |> arg(:block_ids)
      |> List.wrap()

    (explicit ++ block_refs_from_text(text))
    |> Enum.flat_map(&normalize_block_id/1)
    |> Enum.uniq()
  end

  defp block_refs_from_text(text) do
    @block_ref_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_match, id] -> id end)
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
