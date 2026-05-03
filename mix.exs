defmodule Sheaf.MixProject do
  use Mix.Project

  def project do
    [
      app: :sheaf,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: Sheaf.Admin.CLI, path: "bin/sheaf-admin", app: nil],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Sheaf.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :opentelemetry_exporter,
        :opentelemetry
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_req, "~> 1.0"},
      {:opentelemetry_finch, "~> 0.2"},
      {:redix, "~> 1.5"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:nimble_csv, "~> 1.0"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.10"},
      {:exqlite, "~> 0.36.0"},
      {:duckdbex, "~> 0.4.0"},
      {:sqlite_vec, "~> 0.1.0"},
      {:mdex, "~> 0.12"},
      {:rdf, "~> 2.1"},
      {:sheaf_rdf_browser, path: "apps/sheaf_rdf_browser"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "cmd --cd assets bun install",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["compile", "tailwind sheaf", "esbuild sheaf"],
      "assets.deploy": [
        "tailwind sheaf --minify",
        "esbuild sheaf --minify",
        "phx.digest"
      ],
      precommit: [
        "format",
        "test"
      ]
    ]
  end
end
