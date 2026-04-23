defmodule Sheaf.Interviews do
  @moduledoc """
  Imports the IEVA interview export into a dedicated named graph in Fuseki.

  Source storage layout:

    * `interviews.db` stores one JSON document per interview in a `store(key, value)` table
    * `blobs.db` stores content-addressed audio blobs in a `blobs(hash, data, mime_type)` table

  The importer currently reads `interviews.db` and projects the transcript structure into RDF.
  Audio blobs are referenced by stable hash IRIs so the raw audio can be extracted separately later.
  """

  alias Exqlite.Sqlite3
  alias Sheaf.Fuseki
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS
  alias Sheaf.Prov

  @default_graph "https://example.com/sheaf/graph/interviews"
  @default_max_update_bytes 200_000
  @resource_base "https://example.com/sheaf/"
  @xsd_integer "http://www.w3.org/2001/XMLSchema#integer"

  defmodule Interview do
    defstruct [
      :id,
      :source_key,
      :filename,
      :audio_hash,
      :duration,
      :current_position,
      :context_segments,
      :model_name,
      segments: []
    ]
  end

  defmodule Segment do
    defstruct [:index, :start_time, :end_time, :audio_hash, utterances: []]
  end

  defmodule Utterance do
    defstruct [:index, :speaker, :text, :audio_hash]
  end

  def graph do
    Application.get_env(:sheaf, __MODULE__, [])[:graph] || @default_graph
  end

  def default_db_path do
    Application.app_dir(:sheaf, "priv/ieva_data/interviews.db")
  end

  def default_blobs_db_path do
    Application.app_dir(:sheaf, "priv/ieva_data/blobs.db")
  end

  def import(opts \\ []) do
    db_path = Keyword.get(opts, :db_path, default_db_path())
    blobs_db_path = Keyword.get(opts, :blobs_db_path, default_blobs_db_path())
    graph_name = Keyword.get(opts, :graph, graph())
    replace? = Keyword.get(opts, :replace, true)
    max_update_bytes = Keyword.get(opts, :max_update_bytes, @default_max_update_bytes)

    with {:ok, interviews} <- load_interviews(db_path),
         {:ok, blob_metadata} <- load_blob_metadata(blobs_db_path, interviews),
         :ok <- maybe_clear_graph(graph_name, replace?),
         {:ok, inserted_statements} <-
           insert_batches(statements_for(interviews, blob_metadata), graph_name, max_update_bytes) do
      {:ok,
       %{
         db_path: db_path,
         blobs_db_path: blobs_db_path,
         graph: graph_name,
         interviews: length(interviews),
         segments: count_segments(interviews),
         utterances: count_utterances(interviews),
         statements: inserted_statements
       }}
    end
  end

  def load_interviews(db_path \\ default_db_path()) do
    if File.exists?(db_path) do
      with {:ok, conn} <- Sqlite3.open(db_path, [:readonly]) do
        try do
          case fetch_all(conn, "SELECT key, value FROM store ORDER BY CAST(key AS INTEGER), key") do
            {:ok, rows} ->
              interviews =
                Enum.map(rows, fn [source_key, json] ->
                  deserialize_interview(source_key, json)
                end)

              {:ok, interviews}

            {:error, reason} ->
              {:error, format_sqlite_error(reason)}
          end
        after
          :ok = Sqlite3.close(conn)
        end
      else
        {:error, reason} -> {:error, format_sqlite_error(reason)}
      end
    else
      {:error, "Interviews database not found at #{db_path}"}
    end
  end

  def statements_for(interviews) when is_list(interviews) do
    statements_for(interviews, %{})
  end

  def statements_for(interviews, blob_metadata)
      when is_list(interviews) and is_map(blob_metadata) do
    audio_statements =
      interviews
      |> collect_audio_hashes()
      |> Enum.map(&audio_statement(&1, blob_metadata))

    audio_statements ++ Enum.flat_map(interviews, &interview_statements/1)
  end

  def load_blob_metadata(blobs_db_path \\ default_blobs_db_path(), interviews)

  def load_blob_metadata(blobs_db_path, interviews) when is_binary(blobs_db_path) do
    if File.exists?(blobs_db_path) do
      with {:ok, conn} <- Sqlite3.open(blobs_db_path, [:readonly]) do
        try do
          hashes = MapSet.new(collect_audio_hashes(interviews))

          case fetch_all(conn, "SELECT hash, mime_type FROM blobs") do
            {:ok, rows} ->
              metadata =
                Enum.reduce(rows, %{}, fn [hash, mime_type], acc ->
                  if MapSet.member?(hashes, hash) do
                    Map.put(acc, hash, %{mime_type: mime_type})
                  else
                    acc
                  end
                end)

              {:ok, metadata}

            {:error, reason} ->
              {:error, format_sqlite_error(reason)}
          end
        after
          :ok = Sqlite3.close(conn)
        end
      else
        {:error, reason} -> {:error, format_sqlite_error(reason)}
      end
    else
      {:ok, %{}}
    end
  end

  defp fetch_all(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        Sqlite3.fetch_all(conn, statement)
      after
        :ok = Sqlite3.release(conn, statement)
      end
    end
  end

  defp deserialize_interview(source_key, json) do
    payload = Jason.decode!(json)

    %Interview{
      id: string_field(payload, "id") || source_key,
      source_key: source_key,
      filename: string_field(payload, "filename") || "untitled",
      audio_hash: blank_to_nil(payload["audio_hash"]),
      duration: string_field(payload, "duration") || "00:00:00",
      current_position: string_field(payload, "current_position") || "00:00:00",
      context_segments: integer_field(payload, "context_segments") || 1,
      model_name: string_field(payload, "model_name") || "unknown",
      segments:
        payload
        |> Map.get("segments", [])
        |> List.wrap()
        |> Enum.with_index(1)
        |> Enum.map(fn {segment, index} -> deserialize_segment(segment, index) end)
    }
  end

  defp deserialize_segment(segment, index) do
    %Segment{
      index: index,
      start_time: string_field(segment, "start_time") || "00:00:00",
      end_time: string_field(segment, "end_time") || "00:00:00",
      audio_hash: blank_to_nil(segment["audio_hash"]),
      utterances:
        segment
        |> Map.get("utterances", [])
        |> List.wrap()
        |> Enum.with_index(1)
        |> Enum.map(fn {utterance, utterance_index} ->
          deserialize_utterance(utterance, utterance_index)
        end)
    }
  end

  defp deserialize_utterance(utterance, index) do
    %Utterance{
      index: index,
      speaker: string_field(utterance, "speaker") || "unknown",
      text: string_field(utterance, "text") || "",
      audio_hash: blank_to_nil(utterance["audio_hash"])
    }
  end

  defp collect_audio_hashes(interviews) do
    interviews
    |> Enum.flat_map(fn interview ->
      interview_hashes = List.wrap(interview.audio_hash)

      segment_hashes =
        Enum.flat_map(interview.segments, fn segment ->
          [segment.audio_hash | Enum.map(segment.utterances, & &1.audio_hash)]
        end)

      interview_hashes ++ segment_hashes
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp audio_statement(hash, blob_metadata) do
    metadata = Map.get(blob_metadata, hash, %{})

    statement(audio_iri(hash), [
      {"a", [term(SheafNS.AudioBlob)]},
      {term(SheafNS.sourceKey()), [Fuseki.literal(hash)]}
      | maybe_mime_type_predicate(metadata[:mime_type])
    ])
  end

  defp interview_statements(%Interview{} = interview) do
    interview_iri = interview_iri(interview.id)
    sequence_iri = children_iri(interview_iri)

    segment_data =
      interview.segments
      |> Enum.map(&segment_data(interview, &1))

    segment_iris = Enum.map(segment_data, &elem(&1, 0))
    segment_statements = Enum.flat_map(segment_data, &elem(&1, 1))

    [
      statement(interview_iri, [
        {"a", [term(SheafNS.Document), term(SheafNS.Transcript), term(SheafNS.Interview)]},
        {term(SheafNS.title()), [Fuseki.literal(interview.filename)]},
        {term(SheafNS.filename()), [Fuseki.literal(interview.filename)]},
        {term(SheafNS.duration()), [Fuseki.literal(interview.duration)]},
        {term(SheafNS.currentPosition()), [Fuseki.literal(interview.current_position)]},
        {term(SheafNS.contextSegments()), [integer_literal(interview.context_segments)]},
        {term(SheafNS.modelName()), [Fuseki.literal(interview.model_name)]},
        {term(SheafNS.sourceKey()), [Fuseki.literal(interview.source_key)]},
        {term(SheafNS.children()), [Fuseki.iri_ref(sequence_iri)]}
        | maybe_audio_predicate(interview.audio_hash)
      ]),
      sequence_statement(sequence_iri, segment_iris)
      | segment_statements
    ]
  end

  defp segment_data(interview, %Segment{} = segment) do
    segment_iri = segment_iri(interview.id, segment.index)
    sequence_iri = children_iri(segment_iri)

    utterance_data =
      segment.utterances
      |> Enum.map(&utterance_data(interview, segment, &1))

    utterance_iris = Enum.map(utterance_data, &elem(&1, 0))
    utterance_statements = Enum.flat_map(utterance_data, &elem(&1, 1))

    {segment_iri,
     [
       statement(segment_iri, [
         {"a", [term(SheafNS.Segment)]},
         {term(SheafNS.startTime()), [Fuseki.literal(segment.start_time)]},
         {term(SheafNS.endTime()), [Fuseki.literal(segment.end_time)]},
         {term(SheafNS.children()), [Fuseki.iri_ref(sequence_iri)]}
         | maybe_audio_predicate(segment.audio_hash)
       ]),
       sequence_statement(sequence_iri, utterance_iris)
       | utterance_statements
     ]}
  end

  defp utterance_data(interview, segment, %Utterance{} = utterance) do
    utterance_iri = utterance_iri(interview.id, segment.index, utterance.index)
    paragraph_iri = Id.iri(Id.generate())

    {utterance_iri,
     [
       statement(utterance_iri, [
         {"a", [term(SheafNS.ParagraphBlock), term(SheafNS.Utterance)]},
         {term(SheafNS.speaker()), [Fuseki.literal(utterance.speaker)]},
         {term(SheafNS.paragraph()), [Fuseki.iri_ref(paragraph_iri)]}
         | maybe_audio_predicate(utterance.audio_hash)
       ]),
       statement(paragraph_iri, [
         {"a", [term(SheafNS.Paragraph), term(Prov.entity())]},
         {term(SheafNS.text()), [Fuseki.literal(utterance.text)]}
       ])
     ]}
  end

  defp maybe_audio_predicate(nil), do: []

  defp maybe_audio_predicate(hash),
    do: [{term(SheafNS.audio()), [Fuseki.iri_ref(audio_iri(hash))]}]

  defp maybe_mime_type_predicate(nil), do: []

  defp maybe_mime_type_predicate(mime_type),
    do: [{term(SheafNS.mimeType()), [Fuseki.literal(mime_type)]}]

  defp maybe_clear_graph(_graph_name, false), do: :ok

  defp maybe_clear_graph(graph_name, true) do
    Fuseki.update("CLEAR SILENT GRAPH #{Fuseki.iri_ref(graph_name)}")
  end

  defp insert_batches(statements, _graph_name, _max_update_bytes) when statements == [],
    do: {:ok, 0}

  defp insert_batches(statements, graph_name, max_update_bytes) do
    statements
    |> chunk_statements(max_update_bytes)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, inserted} ->
      update = """
      PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

      INSERT DATA {
        GRAPH #{Fuseki.iri_ref(graph_name)} {
          #{Enum.join(chunk, "\n\n")}
        }
      }
      """

      case Fuseki.update(update) do
        :ok -> {:cont, {:ok, inserted + length(chunk)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp chunk_statements(statements, max_update_bytes) do
    {chunks, current_chunk, _current_size} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {chunks, current_chunk, current_size} ->
        statement_size = byte_size(statement) + 2

        if current_chunk != [] and current_size + statement_size > max_update_bytes do
          {[Enum.reverse(current_chunk) | chunks], [statement], statement_size}
        else
          {chunks, [statement | current_chunk], current_size + statement_size}
        end
      end)

    chunks =
      if current_chunk == [] do
        chunks
      else
        [Enum.reverse(current_chunk) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp statement(subject, predicate_objects) do
    body =
      predicate_objects
      |> Enum.map(fn {predicate, objects} -> "#{predicate} #{Enum.join(objects, ", ")}" end)
      |> Enum.join(" ;\n  ")

    "#{Fuseki.iri_ref(subject)} #{body} ."
  end

  defp sequence_statement(sequence_iri, child_iris) do
    statement(sequence_iri, [
      {"a", ["rdf:Seq"]}
      | Enum.with_index(child_iris, 1)
        |> Enum.map(fn {child_iri, index} ->
          {"rdf:_#{index}", [Fuseki.iri_ref(child_iri)]}
        end)
    ])
  end

  defp integer_literal(value) when is_integer(value), do: ~s("#{value}"^^<#{@xsd_integer}>)

  defp interview_iri(id), do: RDF.IRI.new!(@resource_base <> "interviews/" <> URI.encode(id))
  defp segment_iri(id, index), do: RDF.IRI.new!("#{interview_iri(id)}/segments/#{index}")

  defp utterance_iri(id, segment_index, index),
    do: RDF.IRI.new!("#{segment_iri(id, segment_index)}/utterances/#{index}")

  defp children_iri(iri), do: RDF.IRI.new!("#{iri}/children")
  defp audio_iri(hash), do: RDF.IRI.new!(@resource_base <> "audio/" <> hash)
  defp term(iri), do: Fuseki.iri_ref(iri)

  defp count_segments(interviews) do
    Enum.reduce(interviews, 0, fn interview, acc -> acc + length(interview.segments) end)
  end

  defp count_utterances(interviews) do
    Enum.reduce(interviews, 0, fn interview, acc ->
      acc +
        Enum.reduce(interview.segments, 0, fn segment, segment_acc ->
          segment_acc + length(segment.utterances)
        end)
    end)
  end

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      nil -> nil
      value -> to_string(value)
    end
  end

  defp integer_field(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_sqlite_error(reason) when is_binary(reason), do: reason
  defp format_sqlite_error(reason), do: inspect(reason)
end
