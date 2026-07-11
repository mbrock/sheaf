defmodule Sheaf.OpenAI.CoverImages do
  @moduledoc "Generates durable, document-associated cover images with OpenAI."

  require OpenTelemetry.Tracer, as: Tracer
  require RDF.Graph

  alias RDF.{Description, Graph}
  alias Sheaf.{BlobStore, Files, Id}
  alias Sheaf.NS.{DCAT, DCTERMS, DOC, FABIO, PROV}

  @endpoint "https://api.openai.com/v1/images/generations"
  @default_model "gpt-image-2"
  @mime_type "image/png"

  def generate(document_id, prompt, opts \\ [])
      when is_binary(document_id) and is_binary(prompt) do
    prompt = String.trim(prompt)
    model = Keyword.get(opts, :model, @default_model)
    size = Keyword.get(opts, :size, "1024x1536")
    quality = Keyword.get(opts, :quality, "medium")

    Tracer.with_span "sheaf.openai.generate_cover_image", %{
      kind: :client,
      attributes: [
        {"gen_ai.system", "openai"},
        {"gen_ai.request.model", model},
        {"sheaf.document.id", document_id},
        {"sheaf.cover.prompt", prompt},
        {"sheaf.cover.size", size},
        {"sheaf.cover.quality", quality}
      ]
    } do
      with :ok <- validate(document_id, prompt, opts),
           {:ok, key, _source} <- ReqLLM.Keys.get(:openai, opts),
           {:ok, bytes} <- request(prompt, model, size, quality, key, opts),
           {:ok, result} <- persist(document_id, prompt, model, bytes, opts) do
        Tracer.set_attribute("sheaf.cover.byte_size", result.byte_size)
        {:ok, result}
      end
    end
  end

  def fetch(document_id, opts \\ []) when is_binary(document_id) do
    graph = Keyword.get_lazy(opts, :workspace_graph, &workspace_graph/0)

    with %Description{} = document <-
           Graph.description(graph, Id.iri(document_id)),
         %RDF.IRI{} = file_iri <-
           Description.first(document, DOC.coverImage()),
         %Description{} = file <- Graph.description(graph, file_iri),
         {:ok, path} <- Files.local_path(file, opts) do
      {:ok,
       %{
         file_iri: file_iri,
         path: path,
         mime_type: first_value(file, DCAT.mediaType()) || @mime_type
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp request(prompt, model, size, quality, key, opts) do
    request = Keyword.get(opts, :request, &Req.post/2)

    request.(@endpoint,
      auth: {:bearer, key},
      json: %{
        model: model,
        prompt: prompt,
        size: size,
        quality: quality,
        output_format: "png"
      },
      receive_timeout: Keyword.get(opts, :receive_timeout, 300_000)
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 ->
        decode(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_image_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(%{"data" => [%{"b64_json" => encoded} | _]})
       when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_image_base64}
    end
  end

  defp decode(_body), do: {:error, :missing_generated_image}

  defp persist(document_id, prompt, model, bytes, opts) do
    file_iri = Keyword.get_lazy(opts, :file_iri, &Sheaf.mint/0)
    activity_iri = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    filename = "#{document_id}-cover.png"

    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-#{System.unique_integer([:positive])}.png"
      )

    try do
      with :ok <- File.write(path, bytes),
           {:ok, stored} <-
             BlobStore.put_file(path,
               root: Keyword.get(opts, :blob_root, blob_root()),
               filename: filename,
               mime_type: @mime_type
             ),
           graph =
             cover_graph(
               Id.iri(document_id),
               file_iri,
               activity_iri,
               stored,
               prompt,
               model,
               generated_at
             ),
           :ok <- replace_cover_link(Id.iri(document_id), graph, opts) do
        {:ok,
         %{
           document_id: document_id,
           file_id: Id.id_from_iri(file_iri),
           path: "/covers/#{document_id}",
           mime_type: @mime_type,
           byte_size: stored.byte_size,
           prompt: prompt,
           model: model
         }}
      end
    after
      File.rm(path)
    end
  end

  defp cover_graph(
         document,
         file,
         activity,
         stored,
         prompt,
         model,
         generated_at
       ) do
    Graph.new(name: Sheaf.Repo.workspace_graph())
    |> Graph.add({document, DOC.coverImage(), file})
    |> Graph.add({file, RDF.type(), FABIO.ComputerFile})
    |> Graph.add({file, RDF.type(), PROV.Entity})
    |> Graph.add({file, RDF.NS.RDFS.label(), "Cover image"})
    |> Graph.add({file, DCTERMS.identifier(), stored.storage_key})
    |> Graph.add({file, DCAT.mediaType(), @mime_type})
    |> Graph.add({file, DCAT.byteSize(), stored.byte_size})
    |> Graph.add({file, DOC.sha256(), stored.hash})
    |> Graph.add({file, DOC.originalFilename(), stored.original_filename})
    |> Graph.add({file, PROV.wasGeneratedBy(), activity})
    |> Graph.add({file, PROV.generatedAtTime(), generated_at})
    |> Graph.add({activity, RDF.type(), PROV.Activity})
    |> Graph.add({activity, RDF.NS.RDFS.label(), "Cover image generation"})
    |> Graph.add({activity, PROV.used(), document})
    |> Graph.add({activity, PROV.generated(), file})
    |> Graph.add({activity, RDF.NS.RDF.value(), prompt})
    |> Graph.add({activity, DOC.generationModelName(), model})
  end

  defp replace_cover_link(document, graph, opts) do
    transact = Keyword.get(opts, :transact, &Sheaf.Repo.transact/1)

    old_links =
      Keyword.get_lazy(opts, :old_links, fn ->
        workspace_graph()
        |> Graph.triples()
        |> Enum.filter(fn {subject, predicate, _object} ->
          subject == document and predicate == RDF.iri(DOC.coverImage())
        end)
      end)

    changes =
      if old_links == [] do
        [{:assert, graph}]
      else
        old = Graph.new(old_links, name: Sheaf.Repo.workspace_graph())
        [{:retract, old}, {:assert, graph}]
      end

    transact.(changes)
  end

  defp validate(document_id, prompt, opts) do
    resolver = Keyword.get(opts, :resolver, &Sheaf.ResourceResolver.resolve/1)

    cond do
      not Regex.match?(~r/^[A-Za-z0-9]{6}$/, document_id) ->
        {:error, :invalid_document_id}

      prompt == "" ->
        {:error, :prompt_required}

      true ->
        case resolver.(document_id) do
          {:ok, %{kind: :document}} -> :ok
          {:ok, _resource} -> {:error, :not_a_document}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp workspace_graph do
    Sheaf.Repo.ask(&RDF.Dataset.graph(&1, Sheaf.Repo.workspace_graph()))
  end

  defp first_value(description, predicate) do
    case Description.first(description, predicate) do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp blob_root do
    :sheaf
    |> Application.get_env(BlobStore, [])
    |> Keyword.get(:root, "priv/blobs")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
