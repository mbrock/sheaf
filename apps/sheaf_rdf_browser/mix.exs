defmodule SheafRDFBrowser.MixProject do
  use Mix.Project

  def project do
    [
      app: :sheaf_rdf_browser,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SheafRDFBrowser.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:mdex, "~> 0.12"},
      {:rdf, "~> 2.1"},
      {:req, "~> 0.5"}
    ]
  end
end
