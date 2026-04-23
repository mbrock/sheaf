defmodule Sheaf.Id do
  @moduledoc """
  Short, human-usable identifiers for block IRIs.
  """

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @alphabet_size length(@alphabet)
  @length 6
  @base_iri "https://example.com/sheaf/"

  def generate do
    for _ <- 1..@length, into: "" do
      <<Enum.at(@alphabet, :rand.uniform(@alphabet_size) - 1)>>
    end
  end

  def iri(id) when is_binary(id) do
    RDF.IRI.new!(@base_iri <> id)
  end

  def id_from_iri(iri) when is_binary(iri) do
    iri
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.last()
  end
end
