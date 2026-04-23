defmodule Sheaf do
  @moduledoc """
  """

  @doc """
  Generates a new unique IRI for a resource.
  """
  def mint do
    Sheaf.Id.iri(Sheaf.Id.generate())
  end
end
