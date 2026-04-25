defmodule Sheaf.DatalabJobs do
  @moduledoc """
  RDF-backed state for Datalab batch conversion jobs.
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.NS.{DCTERMS, FABIO, PROV}

  @graph "https://less.rest/sheaf/jobs"
  @base "https://less.rest/sheaf/"
  @default_output_format "json"
  @processor RDF.iri("https://www.datalab.to/")

  @type file_job :: %{
          iri: RDF.IRI.t(),
          source_file: RDF.IRI.t() | nil,
          execution_id: String.t() | nil,
          status: String.t() | nil,
          output_format: String.t() | nil,
          output_path: String.t() | nil,
          error: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil
        }

  def graph_name, do: @graph

  def fetch_graph do
    Sheaf.fetch_graph(@graph)
  rescue
    _ -> {:ok, Graph.new()}
  end

  def put_graph(%Graph{} = graph) do
    Sheaf.put_graph(@graph, graph)
  end

  def create_job(source_files, opts \\ []) when is_list(source_files) do
    job_iri = Keyword.get_lazy(opts, :job_iri, &Sheaf.mint/0)
    name = Keyword.get(opts, :name, "PDF conversion batch")
    output_format = Keyword.get(opts, :output_format, @default_output_format)
    now = Keyword.get_lazy(opts, :created_at, &now/0)

    with {:ok, graph} <- fetch_graph() do
      graph =
        graph
        |> add_job(job_iri, name, output_format, now)
        |> then(fn graph ->
          Enum.reduce(source_files, graph, fn source_file, graph ->
            upsert_file_job_graph(graph, job_iri,
              source_file: source_file,
              output_format: output_format
            )
          end)
        end)

      with :ok <- put_graph(graph) do
        {:ok, %{iri: job_iri, graph: graph, file_jobs: list_file_jobs(graph, job_iri)}}
      end
    end
  end

  def add_source_files(job_iri, source_files, opts \\ []) do
    output_format = Keyword.get(opts, :output_format, @default_output_format)

    with {:ok, graph} <- fetch_graph() do
      graph =
        Enum.reduce(source_files, graph, fn source_file, graph ->
          if file_job_for_source(graph, job_iri, source_file) do
            graph
          else
            upsert_file_job_graph(graph, job_iri,
              source_file: source_file,
              output_format: output_format
            )
          end
        end)

      with :ok <- put_graph(graph) do
        {:ok, %{iri: RDF.iri(job_iri), graph: graph, file_jobs: list_file_jobs(graph, job_iri)}}
      end
    end
  end

  def get_job(job_iri) do
    with {:ok, graph} <- fetch_graph() do
      {:ok, %{iri: RDF.iri(job_iri), graph: graph, file_jobs: list_file_jobs(graph, job_iri)}}
    end
  end

  def list_jobs do
    with {:ok, graph} <- fetch_graph() do
      jobs =
        graph
        |> RDF.Data.descriptions()
        |> Enum.filter(&Description.include?(&1, {RDF.type(), term("BatchJob")}))
        |> Enum.map(fn description ->
          %{
            iri: description.subject,
            label: first_value(description, RDFS.label()),
            output_format: first_value(description, DCTERMS.format()),
            created_at: first_value(description, PROV.startedAtTime()),
            file_jobs: list_file_jobs(graph, description.subject)
          }
        end)

      {:ok, jobs}
    end
  end

  def update_file_job(job_iri, source_file, attrs) do
    with {:ok, graph} <- fetch_graph() do
      graph = upsert_file_job_graph(graph, job_iri, Keyword.put(attrs, :source_file, source_file))

      with :ok <- put_graph(graph) do
        {:ok, file_job_for_source(graph, job_iri, source_file)}
      end
    end
  end

  def source_files_in_jobs do
    with {:ok, graph} <- fetch_graph() do
      source_files =
        graph
        |> RDF.Data.descriptions()
        |> Enum.filter(&Description.include?(&1, {RDF.type(), term("FileProcessingJob")}))
        |> Enum.flat_map(&Description.get(&1, PROV.used(), []))
        |> MapSet.new()

      {:ok, source_files}
    end
  end

  def pending_file_jobs(%{file_jobs: file_jobs}) do
    Enum.filter(file_jobs, fn job -> is_nil(job.execution_id) end)
  end

  def submitted_file_jobs(%{file_jobs: file_jobs}) do
    Enum.reject(file_jobs, fn job ->
      is_nil(job.execution_id) or completed?(job) or failed?(job)
    end)
  end

  def completed?(%{completed_at: completed_at}), do: not is_nil(completed_at)
  def failed?(%{failed_at: failed_at}), do: not is_nil(failed_at)

  defp add_job(%Graph{} = graph, job_iri, name, output_format, now) do
    graph
    |> Graph.add({job_iri, RDF.type(), PROV.Activity})
    |> Graph.add({job_iri, RDF.type(), term("BatchJob")})
    |> Graph.add({job_iri, RDFS.label(), RDF.literal(name)})
    |> Graph.add({job_iri, DCTERMS.format(), RDF.literal(output_format)})
    |> Graph.add({job_iri, PROV.wasAssociatedWith(), @processor})
    |> Graph.add({job_iri, PROV.startedAtTime(), RDF.literal(now)})
  end

  defp upsert_file_job_graph(%Graph{} = graph, job_iri, attrs) do
    job_iri = RDF.iri(job_iri)
    source_file = attrs |> Keyword.fetch!(:source_file) |> RDF.iri()
    file_job_iri = file_job_iri(job_iri, source_file)
    attrs = Map.new(attrs)

    graph
    |> Graph.add({@processor, RDF.type(), PROV.SoftwareAgent})
    |> Graph.add({@processor, RDFS.label(), RDF.literal("Datalab")})
    |> Graph.add({file_job_iri, RDF.type(), PROV.Activity})
    |> Graph.add({file_job_iri, RDF.type(), term("FileProcessingJob")})
    |> Graph.add({file_job_iri, term("batchJob"), job_iri})
    |> Graph.add({file_job_iri, PROV.wasInformedBy(), job_iri})
    |> Graph.add({file_job_iri, PROV.wasAssociatedWith(), @processor})
    |> Graph.add({file_job_iri, PROV.used(), source_file})
    |> add_literal(file_job_iri, DCTERMS.identifier(), attrs[:execution_id])
    |> add_literal(file_job_iri, DCTERMS.format(), attrs[:output_format])
    |> add_literal(file_job_iri, PROV.startedAtTime(), attrs[:submitted_at])
    |> add_output(file_job_iri, attrs)
    |> add_failure(file_job_iri, attrs)
  end

  defp list_file_jobs(%Graph{} = graph, job_iri) do
    job_iri = RDF.iri(job_iri)

    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {term("batchJob"), job_iri}))
    |> Enum.map(&file_job_from_description(&1, graph))
    |> Enum.sort_by(&to_string(&1.source_file || &1.iri))
  end

  defp file_job_for_source(%Graph{} = graph, job_iri, source_file) do
    source_file = RDF.iri(source_file)
    Enum.find(list_file_jobs(graph, job_iri), &(&1.source_file == source_file))
  end

  defp file_job_from_description(%Description{} = description, %Graph{} = graph) do
    output = output_description(description, graph)

    %{
      iri: description.subject,
      source_file: Description.first(description, PROV.used()),
      execution_id: first_value(description, DCTERMS.identifier()),
      output_format: first_value(description, DCTERMS.format()),
      output_path: output && first_value(output, term("outputPath")),
      error: first_value(description, term("errorMessage")),
      submitted_at: first_value(description, PROV.startedAtTime()),
      completed_at: output && first_value(output, PROV.generatedAtTime()),
      failed_at: failure_time(description),
      status: derived_status(description, output)
    }
  end

  defp file_job_from_description(_empty, _graph) do
    %{
      iri: nil,
      source_file: nil,
      execution_id: nil,
      status: nil,
      output_format: nil,
      output_path: nil,
      error: nil,
      submitted_at: nil,
      completed_at: nil,
      failed_at: nil
    }
  end

  defp derived_status(%Description{} = description, output) do
    cond do
      output -> "completed"
      Description.first(description, term("errorMessage")) -> "failed"
      Description.first(description, DCTERMS.identifier()) -> "submitted"
      true -> "pending"
    end
  end

  defp add_output(%Graph{} = graph, file_job_iri, attrs) do
    if present?(attrs[:output_path]) and present?(attrs[:completed_at]) do
      output_iri = output_iri(file_job_iri)

      graph
      |> Graph.add({file_job_iri, PROV.generated(), output_iri})
      |> add_literal(file_job_iri, PROV.endedAtTime(), attrs[:completed_at])
      |> Graph.add({output_iri, RDF.type(), PROV.Entity})
      |> Graph.add({output_iri, RDF.type(), FABIO.ComputerFile})
      |> Graph.add({output_iri, PROV.wasGeneratedBy(), file_job_iri})
      |> add_literal(output_iri, PROV.generatedAtTime(), attrs[:completed_at])
      |> add_literal(output_iri, term("outputPath"), attrs[:output_path])
    else
      graph
    end
  end

  defp add_failure(%Graph{} = graph, file_job_iri, attrs) do
    if present?(attrs[:error]) do
      graph
      |> add_literal(file_job_iri, term("errorMessage"), attrs[:error])
      |> add_literal(file_job_iri, PROV.endedAtTime(), attrs[:failed_at] || attrs[:completed_at])
    else
      graph
    end
  end

  defp output_description(%Description{} = description, %Graph{} = graph) do
    description
    |> Description.first(PROV.generated())
    |> case do
      nil -> nil
      output_iri -> Graph.description(graph, output_iri)
    end
  end

  defp failure_time(%Description{} = description) do
    if Description.first(description, term("errorMessage")) do
      first_value(description, PROV.endedAtTime())
    end
  end

  defp add_literal(graph, _subject, _predicate, value) when value in [nil, ""], do: graph

  defp add_literal(%Graph{} = graph, subject, predicate, value) do
    Graph.add(graph, {subject, predicate, RDF.literal(value)})
  end

  defp present?(value), do: value not in [nil, ""]

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> term_value()
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: RDF.Term.value(term)

  defp file_job_iri(job_iri, source_file) do
    RDF.iri("#{job_iri}/tasks/#{Sheaf.Id.id_from_iri(source_file)}")
  end

  defp output_iri(file_job_iri), do: RDF.iri("#{file_job_iri}/output")

  defp term(name), do: RDF.iri(@base <> name)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
