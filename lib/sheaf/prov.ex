defmodule Sheaf.Prov do
  @moduledoc """
  Minimal PROV-O term helpers used by the Sheaf graph model.
  """

  @base_iri "http://www.w3.org/ns/prov#"

  def entity, do: RDF.iri(@base_iri <> "Entity")
  def was_invalidated_by, do: RDF.iri(@base_iri <> "wasInvalidatedBy")
  def was_revision_of, do: RDF.iri(@base_iri <> "wasRevisionOf")
end
