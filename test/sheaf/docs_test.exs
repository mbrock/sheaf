defmodule Sheaf.DocsTest do
  use ExUnit.Case, async: true

  test "renders an overview" do
    text = Sheaf.Docs.render()

    assert text =~ "Sheaf module overview"
    assert text =~ "Application: `:sheaf`"
    assert text =~ "Sheaf.NS - RDF vocabularies used by Sheaf."
    refute text =~ "Useful starting points"
  end

  test "renders another loaded application overview" do
    text = Sheaf.Docs.render([":rdf"])

    assert text =~ "Rdf module overview"
    assert text =~ "Application: `:rdf`"
    assert text =~ "RDF.Graph"
  end

  test "renders function docs" do
    text = Sheaf.Docs.render(["Sheaf.mint/0"])

    assert text =~ "Sheaf.mint/0"
    assert text =~ "Generates a new unique IRI"
  end

  test "can include source clips" do
    text = Sheaf.Docs.render(["Sheaf.mint/0"], include_source: true)

    assert text =~ "Source excerpt"
    assert text =~ "def mint"
  end
end
