defmodule Sheaf.Assistant.Notes do
  @moduledoc """
  Persistent assistant-authored research notes.

  Notes are stored as RDF facts with ActivityStreams vocabulary for the note
  shape and Sheaf vocabulary for block mentions. The writer appends facts with
  SPARQL `INSERT DATA` in the workspace graph; it does not revise or delete
  older notes.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.BlockRefs
  alias Sheaf.Id
  require OpenTelemetry.Tracer, as: Tracer
  require RDF.Graph

  @default_limit 20

  @doc """
  Lists recently published assistant notes.
  """
  def list(opts \\ []) do
    with {:ok, graph} <- list_graph(opts) do
      {:ok, descriptions(graph)}
    end
  end

  @doc """
  Returns a graph describing recently published assistant notes.
  """
  def list_graph(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    Tracer.with_span "Sheaf.Assistant.Notes.list_graph", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"sheaf.limit", limit}
      ]
    } do
      with :ok <- load_notes_cache() do
        graph = Sheaf.Repo.ask(&from_dataset(&1, limit))
        Tracer.set_attribute("sheaf.statement_count", RDF.Data.statement_count(graph))
        {:ok, graph}
      end
    end
  end

  @doc """
  Returns note descriptions from RDF data, newest first.
  """
  def descriptions(data) do
    data
    |> RDF.Data.descriptions()
    |> Enum.filter(&note?/1)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  @doc """
  Builds and persists a note, returning the note resource.

  Required attrs:

    * `:text` - note body
    * `:agent_iri` or `:agent_id`
    * `:session_iri` or `:session_id`

  Optional attrs:

    * `:block_ids` - explicit mentioned block ids
    * `:title`
    * `:agent_label`
    * `:session_label`
    * `:conversation_mode`

  Options:

    * `:note_iri` - deterministic note IRI for tests/imports
    * `:published_at` - deterministic timestamp
    * `:update` - function called with a query label and SPARQL update text
  """
  def write(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, graph} <- build(attrs, opts),
         [note | _] <- descriptions(graph),
         :ok <- persist(graph, opts) do
      {:ok, note.subject}
    else
      [] -> {:error, "note graph did not contain an ActivityStreams note"}
      error -> error
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
        RDF.Graph.build note: note_iri,
                        agent: agent_iri,
                        session: session_iri,
                        text: text,
                        published_at: published_at,
                        block_ids: block_ids,
                        title: optional_text(attrs, :title),
                        agent_label: optional_text(attrs, :agent_label),
                        session_label: optional_text(attrs, :session_label),
                        conversation_mode: optional_text(attrs, :conversation_mode) do
          @prefix Sheaf.NS.AS
          @prefix Sheaf.NS.DOC
          @prefix Sheaf.NS.PROV
          @prefix RDF.NS.RDFS

          note
          |> a(AS.Note)
          |> a(DOC.ResearchNote)
          |> AS.attributedTo(agent)
          |> AS.context(session)
          |> AS.published(published_at)
          |> AS.content(text)
          |> RDFS.label(title)
          |> DOC.mentions(Enum.map(block_ids, &Sheaf.Id.iri/1))

          agent
          |> a(PROV.SoftwareAgent)
          |> RDFS.label(agent_label)

          session
          |> a(DOC.AssistantConversation)
          |> a(AS.OrderedCollection)
          |> RDFS.label(session_label)
          |> AS.name(session_label)
          |> DOC.conversationMode(conversation_mode)
          |> AS.items(note)
        end

      {:ok, graph}
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
      GRAPH <#{Sheaf.Workspace.graph()}> {
    #{indent(triples, 4)}
      }
    }
    """
  end

  defp persist(%Graph{} = graph, opts) do
    update = Keyword.get(opts, :update, &Sheaf.update/2)

    case update.("assistant note insert", insert_data(graph)) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_update_result, other}}
    end
  end

  @doc false
  def from_dataset(dataset, limit \\ @default_limit) do
    limit = normalize_limit(limit)

    Tracer.with_span "Sheaf.Assistant.Notes.from_dataset", %{
      kind: :internal,
      attributes: [
        {"sheaf.limit", limit},
        {"sheaf.statement_count", RDF.Data.statement_count(dataset)}
      ]
    } do
      graph = union_graph(dataset)
      index = graph_index(graph)

      notes =
        graph
        |> RDF.Data.descriptions()
        |> Enum.filter(&note_candidate?/1)
        |> Enum.sort_by(&sort_key/1, :desc)
        |> Enum.take(limit)

      Tracer.set_attribute("sheaf.note_candidate_count", length(notes))

      output =
        Enum.reduce(notes, Graph.new(), fn note, output ->
          add_note_neighborhood(output, index, note)
        end)

      Tracer.set_attribute("sheaf.statement_count", RDF.Data.statement_count(output))
      output
    end
  end

  defp load_notes_cache do
    Sheaf.Repo.load_once({nil, nil, nil, RDF.iri(Sheaf.Repo.workspace_graph())})
  end

  defp union_graph(dataset) do
    dataset
    |> RDF.Dataset.graphs()
    |> Enum.flat_map(&Graph.triples/1)
    |> Graph.new()
  end

  defp add_note_neighborhood(output, index, %Description{} = note) do
    subject = Description.subject(note)
    content = first_object(index, subject, Sheaf.NS.AS.content())

    if Description.include?(note, {RDF.type(), Sheaf.NS.AS.Note}) and content do
      output
      |> add(subject, RDF.type(), Sheaf.NS.AS.Note)
      |> add(subject, RDF.type(), Sheaf.NS.DOC.ResearchNote)
      |> add(subject, Sheaf.NS.AS.content(), content)
      |> add_first(index, subject, Sheaf.NS.AS.published())
      |> add_first(index, subject, Sheaf.NS.AS.attributedTo())
      |> add_first(index, subject, Sheaf.NS.AS.context())
      |> add_first(index, subject, RDF.NS.RDFS.label())
      |> add_all(index, subject, Sheaf.NS.DOC.mentions())
      |> add_agent_neighborhood(index, first_object(index, subject, Sheaf.NS.AS.attributedTo()))
      |> add_context_neighborhood(
        index,
        subject,
        first_object(index, subject, Sheaf.NS.AS.context())
      )
    else
      output
    end
  end

  defp add_agent_neighborhood(output, _index, nil), do: output

  defp add_agent_neighborhood(output, index, agent) do
    output
    |> add(agent, RDF.type(), Sheaf.NS.PROV.SoftwareAgent)
    |> add_first(index, agent, RDF.NS.RDFS.label())
  end

  defp add_context_neighborhood(output, _index, _note, nil), do: output

  defp add_context_neighborhood(output, index, note, context) do
    output =
      output
      |> add(context, RDF.type(), Sheaf.NS.DOC.AssistantConversation)
      |> add(context, RDF.type(), Sheaf.NS.AS.OrderedCollection)
      |> add_first(index, context, RDF.NS.RDFS.label())
      |> add_first(index, context, Sheaf.NS.DOC.conversationMode())
      |> add(context, Sheaf.NS.AS.items(), note)

    index
    |> subjects_with(Sheaf.NS.AS.context(), context)
    |> Enum.map(&description(index, &1))
    |> Enum.filter(&question?/1)
    |> Enum.reduce(output, fn question, output ->
      add_question_neighborhood(output, index, context, question)
    end)
  end

  defp add_question_neighborhood(output, index, context, %Description{} = question) do
    subject = Description.subject(question)
    actor = first_object(index, subject, Sheaf.NS.AS.attributedTo())

    output
    |> add(context, Sheaf.NS.AS.items(), subject)
    |> add(subject, RDF.type(), Sheaf.NS.DOC.Message)
    |> add(subject, Sheaf.NS.AS.context(), context)
    |> add_first(index, subject, Sheaf.NS.AS.content())
    |> add_first(index, subject, Sheaf.NS.AS.published())
    |> add_first(index, subject, Sheaf.NS.AS.attributedTo())
    |> add_actor_label(index, actor)
  end

  defp add_actor_label(output, _index, nil), do: output

  defp add_actor_label(output, index, actor),
    do: add_first(output, index, actor, RDF.NS.RDFS.label())

  defp add_first(output, index, subject, predicate),
    do: add(output, subject, predicate, first_object(index, subject, predicate))

  defp add_all(output, index, subject, predicate) do
    index
    |> objects_for(subject, predicate)
    |> Enum.reduce(output, &add(&2, subject, predicate, &1))
  end

  defp add(output, _subject, _predicate, nil), do: output

  defp add(output, subject, predicate, object),
    do: Graph.add(output, {subject, predicate, object})

  defp note_candidate?(%Description{} = description) do
    Description.include?(description, {RDF.type(), Sheaf.NS.DOC.ResearchNote}) or
      legacy_note?(description)
  end

  defp legacy_note?(%Description{} = description) do
    Description.include?(description, {RDF.type(), Sheaf.NS.AS.Note}) and
      Description.first(description, RDF.NS.RDFS.label()) != nil and
      Description.first(description, Sheaf.NS.AS.inReplyTo()) == nil
  end

  defp question?(%Description{} = description) do
    Description.include?(description, {RDF.type(), Sheaf.NS.DOC.Message}) and
      Description.first(description, Sheaf.NS.AS.content()) != nil and
      Description.first(description, Sheaf.NS.AS.inReplyTo()) == nil
  end

  defp description(index, subject) do
    index
    |> objects_for(subject, nil)
    |> Enum.map(fn {predicate, object} -> {subject, predicate, object} end)
    |> Graph.new()
    |> RDF.Data.description(subject)
  end

  defp first_object(index, subject, predicate),
    do: index |> objects_for(subject, predicate) |> List.first()

  defp objects_for(%{by_sp: by_sp}, subject, nil) do
    by_sp
    |> Enum.flat_map(fn
      {{^subject, predicate}, objects} -> Enum.map(objects, &{predicate, &1})
      _other -> []
    end)
  end

  defp objects_for(%{by_sp: by_sp}, subject, predicate),
    do: Map.get(by_sp, {subject, predicate}, [])

  defp subjects_with(%{by_po: by_po}, predicate, object),
    do: Map.get(by_po, {predicate, object}, [])

  defp graph_index(graph) do
    Enum.reduce(Graph.triples(graph), %{by_sp: %{}, by_po: %{}}, fn {subject, predicate, object},
                                                                    index ->
      index
      |> Map.update!(
        :by_sp,
        &Map.update(&1, {subject, predicate}, [object], fn objects -> [object | objects] end)
      )
      |> Map.update!(
        :by_po,
        &Map.update(&1, {predicate, object}, [subject], fn subjects -> [subject | subjects] end)
      )
    end)
  end

  defp note?(%Description{} = description) do
    Description.include?(description, {RDF.type(), Sheaf.NS.AS.Note})
  end

  defp sort_key(%Description{} = note) do
    note
    |> Description.first(Sheaf.NS.AS.published())
    |> term_value()
    |> case do
      %DateTime{} = published_at -> DateTime.to_unix(published_at)
      nil -> 0
      published_at -> to_string(published_at)
    end
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

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

  defp indent(text, spaces)
  defp indent("", _spaces), do: ""

  defp indent(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(padding <> &1))
  end

  defp arg(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
