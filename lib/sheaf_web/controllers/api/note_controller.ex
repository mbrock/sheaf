defmodule SheafWeb.API.NoteController do
  @moduledoc """
  JSON API for persisted assistant research notes.
  """

  use SheafWeb, :controller

  alias RDF.Description
  alias RDF.NS.RDFS
  alias Sheaf.{Assistant.Notes, Id}
  alias Sheaf.NS.AS
  alias Sheaf.NS.DOC

  def index(conn, _params) do
    case Notes.list() do
      {:ok, notes} ->
        json(conn, %{notes: Enum.map(notes, &summary/1)})

      {:error, reason} ->
        send_error(conn, 502, "failed to list research notes", reason)
    end
  end

  defp summary(%Description{} = note) do
    %{
      id: Id.id_from_iri(note.subject),
      iri: to_string(note.subject),
      title: literal_value(note, RDFS.label()),
      text: literal_value(note, AS.content()),
      published: published_value(note),
      context: iri_value(note, AS.context()),
      attributed_to: iri_value(note, AS.attributedTo()),
      mentions: iri_values(note, DOC.mentions())
    }
  end

  defp literal_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> term_value()
  end

  defp published_value(%Description{} = description) do
    description
    |> Description.first(AS.published())
    |> term_value()
    |> case do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> value
    end
  end

  defp iri_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> case do
      nil -> nil
      iri -> %{id: Id.id_from_iri(iri), iri: to_string(iri)}
    end
  end

  defp iri_values(%Description{} = description, predicate) do
    description
    |> Description.get(predicate, [])
    |> Enum.map(&%{id: Id.id_from_iri(&1), iri: to_string(&1)})
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    RDF.Term.value(term)
  end

  defp send_error(conn, status, message, reason) do
    conn
    |> put_status(status)
    |> json(%{error: message, reason: inspect(reason)})
  end
end
