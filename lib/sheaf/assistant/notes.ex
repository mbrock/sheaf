defmodule Sheaf.Assistant.Notes do
  @moduledoc """
  Persistent assistant-authored research notes.

  Notes are stored as RDF facts with ActivityStreams vocabulary for the note
  shape and Sheaf vocabulary for block mentions. The writer appends facts with
  SPARQL `INSERT DATA`; it does not revise or delete older notes.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.BlockRefs
  alias Sheaf.Id
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
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_limit()
    |> list_query()
    |> then(&Sheaf.query("assistant notes list construct", &1))
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
    #{indent(triples)}
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

  defp list_query(limit) do
    """
    PREFIX as: <https://www.w3.org/ns/activitystreams#>
    PREFIX prov: <http://www.w3.org/ns/prov#>
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    CONSTRUCT {
      ?note a as:Note ;
        a sheaf:ResearchNote ;
        as:content ?content ;
        as:published ?published ;
        as:attributedTo ?agent ;
        as:context ?context ;
        rdfs:label ?title ;
        sheaf:mentions ?mention .

      ?agent a prov:SoftwareAgent ;
        rdfs:label ?agentLabel .

      ?context a sheaf:AssistantConversation ;
        a as:OrderedCollection ;
        rdfs:label ?contextLabel ;
        sheaf:conversationMode ?contextMode ;
        as:items ?note ;
        as:items ?question .

      ?question a sheaf:Message ;
        as:content ?questionContent ;
        as:published ?questionPublished ;
        as:attributedTo ?questionActor ;
        as:context ?context .

      ?questionActor rdfs:label ?questionActorLabel .
    }
    WHERE {
      {
        SELECT ?note ?published WHERE {
          {
            ?note a sheaf:ResearchNote .
          }
          UNION
          {
            ?note a as:Note ;
              rdfs:label ?legacyTitle .
            FILTER NOT EXISTS { ?note as:inReplyTo ?replyTarget }
          }
          OPTIONAL { ?note as:published ?published }
        }
        ORDER BY DESC(?published)
        LIMIT #{limit}
      }

      ?note a as:Note .
      ?note as:content ?content .
      OPTIONAL { ?note rdfs:label ?title }
      OPTIONAL {
        ?note as:attributedTo ?agent .
        OPTIONAL { ?agent rdfs:label ?agentLabel }
      }
      OPTIONAL {
        ?note as:context ?context .
        OPTIONAL { ?context rdfs:label ?contextLabel }
        OPTIONAL { ?context sheaf:conversationMode ?contextMode }
        OPTIONAL {
          ?question a sheaf:Message ;
            as:context ?context ;
            as:content ?questionContent .
          FILTER NOT EXISTS { ?question as:inReplyTo ?questionReplyTarget }
          OPTIONAL { ?question as:published ?questionPublished }
          OPTIONAL {
            ?question as:attributedTo ?questionActor .
            OPTIONAL { ?questionActor rdfs:label ?questionActorLabel }
          }
        }
      }
      OPTIONAL { ?note sheaf:mentions ?mention }
    }
    """
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

  defp indent(""), do: ""

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp arg(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
