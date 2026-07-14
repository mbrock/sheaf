defmodule Sheaf.OpenAI.Images do
  @moduledoc "Generates durable image resources with OpenAI."

  require OpenTelemetry.Tracer, as: Tracer
  require RDF.Graph

  alias RDF.{Description, Graph}
  alias Sheaf.{BlobStore, Files, Id}
  alias Sheaf.NS.{DCAT, DCTERMS, DOC, FABIO, PROV}

  @endpoint "https://api.openai.com/v1/images/generations"
  @default_model "gpt-image-2"
  @output_format "webp"
  @output_compression 82
  @mime_type "image/webp"

  def generate(prompt, opts \\ []) when is_binary(prompt) do
    prompt = String.trim(prompt)
    model = Keyword.get(opts, :model, @default_model)
    size = Keyword.get(opts, :size, "1024x1536")
    quality = Keyword.get(opts, :quality, "medium")

    Tracer.with_span "sheaf.openai.generate_image", %{
      kind: :client,
      attributes: [
        {"gen_ai.system", "openai"},
        {"gen_ai.request.model", model},
        {"sheaf.image.prompt", prompt},
        {"sheaf.image.size", size},
        {"sheaf.image.quality", quality}
      ]
    } do
      with :ok <- require_prompt(prompt),
           {:ok, key, _source} <- ReqLLM.Keys.get(:openai, opts),
           {:ok, bytes} <- request(prompt, model, size, quality, key, opts),
           {:ok, result} <- persist(prompt, model, bytes, opts) do
        Tracer.set_attributes([
          {"sheaf.image.id", result.image_id},
          {"sheaf.image.byte_size", result.byte_size}
        ])

        {:ok, result}
      end
    end
  end

  def fetch(image_id, opts \\ []) when is_binary(image_id) do
    graph = Keyword.get_lazy(opts, :workspace_graph, &workspace_graph/0)

    with %Description{} = file <- Graph.description(graph, Id.iri(image_id)),
         true <- image_file?(file),
         {:ok, path} <- Files.local_path(file, opts) do
      {:ok,
       %{
         image_id: image_id,
         iri: file.subject,
         path: path,
         mime_type: first_value(file, DCAT.mediaType()),
         sha256: first_value(file, DOC.sha256())
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
        output_format: @output_format,
        output_compression: @output_compression
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

  defp persist(prompt, model, bytes, opts) do
    image_iri = Keyword.get_lazy(opts, :image_iri, &Sheaf.mint/0)
    image_id = Id.id_from_iri(image_iri)
    activity_iri = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    filename = "#{image_id}.webp"

    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-#{System.unique_integer([:positive])}.webp"
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
             image_graph(
               image_iri,
               activity_iri,
               stored,
               prompt,
               model,
               generated_at
             ),
           assert_graph =
             Keyword.get(opts, :assert_graph, &Sheaf.Repo.assert/1),
           :ok <- assert_graph.(graph) do
        {:ok,
         %{
           image_id: image_id,
           iri: to_string(image_iri),
           path: "/images/#{image_id}",
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

  defp image_graph(image, activity, stored, prompt, model, generated_at) do
    Graph.new(name: Sheaf.Repo.workspace_graph())
    |> Graph.add({image, RDF.type(), FABIO.ComputerFile})
    |> Graph.add({image, RDF.type(), PROV.Entity})
    |> Graph.add({image, RDF.NS.RDFS.label(), "Generated image"})
    |> Graph.add({image, DCTERMS.identifier(), stored.storage_key})
    |> Graph.add({image, DCAT.mediaType(), @mime_type})
    |> Graph.add({image, DCAT.byteSize(), stored.byte_size})
    |> Graph.add({image, DOC.sha256(), stored.hash})
    |> Graph.add({image, DOC.originalFilename(), stored.original_filename})
    |> Graph.add({image, PROV.wasGeneratedBy(), activity})
    |> Graph.add({image, PROV.generatedAtTime(), generated_at})
    |> Graph.add({activity, RDF.type(), PROV.Activity})
    |> Graph.add({activity, RDF.NS.RDFS.label(), "Image generation"})
    |> Graph.add({activity, PROV.generated(), image})
    |> Graph.add({activity, RDF.NS.RDF.value(), prompt})
    |> Graph.add({activity, DOC.generationModelName(), model})
  end

  defp image_file?(description) do
    mime_type = first_value(description, DCAT.mediaType())

    Description.include?(description, {RDF.type(), FABIO.ComputerFile}) and
      is_binary(mime_type) and String.starts_with?(mime_type, "image/")
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

  defp require_prompt(""), do: {:error, :prompt_required}
  defp require_prompt(_prompt), do: :ok

  defp blob_root do
    :sheaf
    |> Application.get_env(BlobStore, [])
    |> Keyword.get(:root, "priv/blobs")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
