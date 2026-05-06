defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Corpus-aware assistant chat component.

  The component renders and controls a selected `Sheaf.Assistant.Chat`
  process. Conversation state lives in OTP processes so reloads and multiple
  LiveViews can subscribe to the same chat.
  """

  use SheafWeb, :live_component

  import SheafWeb.AssistantActivityComponents

  import SheafWeb.DocumentEntryComponents,
    only: [document_metadata_lines: 1, document_title_line: 1]

  alias Sheaf.Assistant.{Chat, Chats, CorpusTools}
  alias Sheaf.Assistant.ToolResults
  alias Sheaf.Assistant.ToolResults.PresentedSpreadsheetQueryResult
  alias Sheaf.{Document, Id}
  alias SheafWeb.{AssistantMarkdownComponents, BlockPreviewComponent, DataTableComponents}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:chats, [])
     |> assign(:chat, empty_chat())
     |> assign(:selected_chat_id, nil)
     |> assign(:subscribed_chat_id, nil)
     |> assign(:chats_subscribed?, false)
     |> assign(:mode, "quick")
     |> assign(:model, Sheaf.LLM.default_model())
     |> assign(:model_provider, Sheaf.LLM.default_assistant_provider())
     |> assign(:form, chat_form())}
  end

  @impl true
  def update(%{chat_snapshot: snapshot}, socket) do
    socket =
      if socket.assigns.selected_chat_id == snapshot.id do
        socket
        |> assign(:chat, snapshot)
        |> assign(:model, chat_model(snapshot))
        |> assign(:model_provider, chat_model_provider(snapshot))
        |> assign(
          :form,
          chat_form(
            chat_mode(snapshot),
            chat_model_provider(snapshot),
            current_form_message(socket)
          )
        )
        |> maybe_refresh_chat_list()
      else
        maybe_refresh_chat_list(socket)
      end

    {:ok, socket}
  end

  def update(%{assistant_chats: chats}, socket) do
    socket =
      socket
      |> assign(:chats, chats)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:model, fn -> Sheaf.LLM.default_model() end)
      |> assign_new(:model_provider, fn ->
        Sheaf.LLM.assistant_provider_for_model(socket.assigns.model)
      end)
      |> assign_new(:llm_options, fn -> [] end)
      |> assign_new(:variant, fn -> :full end)
      |> assign_new(:composer_only?, fn -> false end)
      |> maybe_ensure_chat_index_subscription()
      |> maybe_ensure_selected_chat()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_chat", %{"id" => id}, socket) do
    socket =
      if chat_listed?(socket.assigns.chats, id) do
        select_chat(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("set_options", %{"chat" => chat_params}, socket) do
    options_locked? = is_binary(socket.assigns.selected_chat_id)

    mode =
      if options_locked? do
        socket.assigns.mode
      else
        chat_params |> Map.get("mode", socket.assigns.mode) |> normalize_mode()
      end

    model_provider =
      if options_locked? do
        socket.assigns.model_provider
      else
        chat_params
        |> Map.get("model_provider", socket.assigns.model_provider)
        |> normalize_model_provider()
      end

    model = Sheaf.LLM.assistant_model_for_provider(model_provider)
    message = Map.get(chat_params, "message", "")

    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:model_provider, model_provider)
     |> assign(:model, model)
     |> assign(:form, chat_form(mode, model_provider, message))}
  end

  def handle_event("new_chat", %{"mode" => mode}, socket) do
    mode = normalize_mode(mode)
    {:noreply, start_blank_chat(socket, mode)}
  end

  def handle_event("promote_note", %{"index" => index}, socket) do
    with {message_index, ""} <- Integer.parse(index),
         chat_id when is_binary(chat_id) <- socket.assigns.selected_chat_id,
         {:ok, _note} <- Chat.promote_assistant_message(chat_id, message_index) do
      {:noreply, socket}
    else
      _error ->
        {:noreply, put_local_error(socket, "Could not promote that response to a note.")}
    end
  end

  def handle_event("send", %{"chat" => %{"message" => message} = chat_params}, socket) do
    mode = Map.get(chat_params, "mode", socket.assigns.mode)
    model_provider = Map.get(chat_params, "model_provider", socket.assigns.model_provider)
    message = String.trim(message)
    mode = normalize_mode(mode)
    model_provider = normalize_model_provider(model_provider)
    model = Sheaf.LLM.assistant_model_for_provider(model_provider)

    cond do
      message == "" ->
        {:noreply,
         socket
         |> assign(:mode, mode)
         |> assign(:model_provider, model_provider)
         |> assign(:model, model)
         |> assign(:form, chat_form(mode, model_provider))}

      socket.assigns.chat.pending ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> assign(:mode, mode)
          |> assign(:model_provider, model_provider)
          |> assign(:model, model)
          |> ensure_sendable_chat(mode)

        socket =
          if is_nil(socket.assigns.selected_chat_id) do
            put_local_error(socket, "No assistant chat is selected.")
          else
            llm_options = assistant_llm_options(socket.assigns.llm_options, model, mode)

            case put_chat_route(socket.assigns.selected_chat_id, model, llm_options) do
              :ok ->
                case Chat.send_user_message(
                       socket.assigns.selected_chat_id,
                       message,
                       turn_context(socket.assigns)
                     ) do
                  :ok ->
                    socket
                    |> assign(:form, chat_form(mode, model_provider))
                    |> maybe_navigate_after_send()

                  {:error, :busy} ->
                    socket

                  {:error, :empty_message} ->
                    assign(socket, :form, chat_form(mode, model_provider))

                  {:error, reason} ->
                    put_local_error(socket, "Assistant error: #{inspect(reason)}")
                end

              {:error, reason} ->
                put_local_error(socket, "Could not switch assistant route: #{inspect(reason)}")
            end
          end

        {:noreply, socket}
    end
  end

  @impl true
  def render(%{variant: :full_page} = assigns) do
    ~H"""
    <section class="min-w-0 py-3">
      <.live_component module={BlockPreviewComponent} id={block_preview_id(@id)} />
      <div
        id={"assistant-timeline-#{@id}"}
        phx-hook="ScrollContainer"
        data-scroll-stick-bottom="false"
        data-scroll-target="window"
      >
        <div
          id={"assistant-timeline-#{@id}-body"}
          class="mx-auto flex min-h-full w-full max-w-prose min-w-0 flex-col justify-end"
        >
          <.chat_item
            :for={{item, index} <- @chat.messages |> message_groups() |> Enum.with_index()}
            item={item}
            message_id={"assistant-message-#{@id}-#{index}"}
            titles={Map.get(@chat, :titles, %{})}
            block_ref_target={block_preview_target(@id)}
            myself={@myself}
          />

          <div
            :if={@chat.pending}
            class="flex items-center gap-2 px-1 py-2 text-stone-500 dark:text-stone-400"
          >
            <span class="size-2.5 shrink-0 animate-pulse rounded-full bg-stone-500 dark:bg-stone-300">
            </span>
            <span class="min-w-0 flex-1 truncate">{@chat.status_line || "Thinking"}</span>
          </div>

          <.composer_form
            :if={!@chat.pending}
            form={@form}
            mode={@mode}
            model_provider={@model_provider}
            selected_chat_id={@selected_chat_id}
            selected_id={Map.get(assigns, :selected_id)}
            pending={@chat.pending}
            myself={@myself}
            id={@id}
          />
        </div>
      </div>

      <button
        type="button"
        data-scroll-bottom-button={"assistant-timeline-#{@id}"}
        class="fixed bottom-6 left-1/2 z-20 grid size-11 -translate-x-1/2 place-items-center rounded-full border border-stone-200/80 bg-white/90 text-stone-900 shadow-lg shadow-stone-950/10 backdrop-blur transition hover:bg-white focus:outline-none focus:ring-2 focus:ring-stone-400 dark:border-stone-700/80 dark:bg-stone-900/90 dark:text-stone-100 dark:shadow-black/30 dark:hover:bg-stone-850"
        title="Scroll to bottom"
        aria-label="Scroll to bottom"
        hidden
      >
        <.icon name="hero-arrow-down" class="size-5" />
      </button>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class={assistant_section_class(@variant, @selected_chat_id)}>
      <.live_component module={BlockPreviewComponent} id={block_preview_id(@id)} />
      <div
        :if={not inline?(@variant) and not sidebar?(@variant) and not @composer_only?}
        class="mb-3 space-y-2"
      >
        <div class="flex items-center gap-2">
          <div class="min-w-0 flex-1">
            <div class="font-sans uppercase text-stone-500 dark:text-stone-400">
              Current
            </div>
            <div class="truncate font-sans  text-stone-800 dark:text-stone-100">
              {current_chat_title(@chat, @selected_chat_id)}
            </div>
          </div>
          <button
            type="button"
            phx-click="new_chat"
            phx-value-mode={@mode}
            phx-target={@myself}
            class="grid size-8 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
            title="New conversation"
            aria-label="New conversation"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </div>

        <div
          :if={@chats != []}
          class="flex max-w-full gap-1 overflow-x-auto pb-1 font-sans"
          aria-label="Assistant conversations"
        >
          <button
            :for={chat <- @chats}
            type="button"
            phx-click="select_chat"
            phx-value-id={chat.id}
            phx-target={@myself}
            class={chat_tab_class(@selected_chat_id, chat)}
            title={chat.title}
          >
            <.icon name={chat_kind_icon(chat)} class="size-3.5 shrink-0" />
            <span class="min-w-0 truncate">{chat.title}</span>
          </button>
        </div>
      </div>

      <.composer_form
        form={@form}
        mode={@mode}
        model_provider={@model_provider}
        selected_chat_id={@selected_chat_id}
        selected_id={Map.get(assigns, :selected_id)}
        pending={@chat.pending}
        myself={@myself}
        id={@id}
      />

      <div
        :if={not inline?(@variant) and not @composer_only? and @selected_chat_id}
        id={"assistant-timeline-#{@id}"}
        class="mt-3 max-h-80 min-h-0 space-y-2 overflow-y-auto pr-1"
        phx-hook="ScrollContainer"
        data-scroll-stick-bottom="true"
      >
        <.chat_item
          :for={{item, index} <- @chat.messages |> message_groups() |> Enum.with_index()}
          item={item}
          message_id={"assistant-message-#{@id}-#{index}"}
          titles={Map.get(@chat, :titles, %{})}
          block_ref_target={block_preview_target(@id)}
          myself={@myself}
        />

        <div
          :if={@chat.pending}
          class="flex items-center gap-2 px-1 py-2 text-stone-500 dark:text-stone-400"
        >
          <span class="size-2.5 shrink-0 animate-pulse rounded-full bg-stone-500 dark:bg-stone-300">
          </span>
          <span class="min-w-0 flex-1 truncate">{@chat.status_line || "Thinking"}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :mode, :string, required: true
  attr :model_provider, :string, required: true
  attr :selected_chat_id, :string, default: nil
  attr :selected_id, :string, default: nil
  attr :pending, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  defp composer_form(assigns) do
    assigns = assign(assigns, :options_locked?, is_binary(assigns.selected_chat_id))

    ~H"""
    <.form
      for={@form}
      phx-change="set_options"
      phx-submit="send"
      phx-target={@myself}
      class="min-w-0"
    >
      <div
        :if={@options_locked?}
        class="grid grid-cols-[1fr_auto] overflow-hidden border border-l-6  border-emerald-300/80 bg-white transition-colors focus-within:border-stone-400 dark:border-stone-800 dark:bg-stone-900 dark:shadow-black/20 dark:focus-within:border-stone-600"
      >
        <.input
          field={@form[:message]}
          type="textarea"
          rows="1"
          class="block w-full overflow-y-auto border-0 bg-transparent px-3 text-base leading-6 text-stone-950 outline-none [field-sizing:content] [resize:none] placeholder:text-stone-400 focus:ring-0 sm:sm dark:text-stone-50 dark:placeholder:text-stone-500"
          placeholder={input_placeholder(@mode, @selected_chat_id)}
          disabled={@pending}
          phx-hook="SubmitShortcut"
        />
        <div class="flex min-w-0 items-center gap-1bg-stone-50/80 font-sans dark:border-stone-800 dark:bg-stone-950/30">
          <.selected_context_badge selected_id={@selected_id} />
          <button
            type="submit"
            class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 disabled:cursor-not-allowed disabled:text-stone-300 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50 dark:disabled:text-stone-700"
            title="Send"
            aria-label="Send"
            disabled={@pending}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </div>

      <div
        :if={!@options_locked?}
        class="overflow-hidden rounded-lg border border-stone-200 bg-white shadow-sm shadow-stone-950/5 transition-colors focus-within:border-stone-400 dark:border-stone-800 dark:bg-stone-900 dark:shadow-black/20 dark:focus-within:border-stone-600"
      >
        <.input
          field={@form[:message]}
          type="textarea"
          rows="1"
          class="block max-h-40 min-h-24 w-full resize-none overflow-y-auto border-0 bg-transparent px-3 py-3 text-base leading-6 text-stone-950 outline-none [field-sizing:content] placeholder:text-stone-400 focus:ring-0 sm:sm dark:text-stone-50 dark:placeholder:text-stone-500"
          placeholder={input_placeholder(@mode, @selected_chat_id)}
          disabled={@pending}
          phx-hook="SubmitShortcut"
        />

        <div class="flex min-w-0 items-center gap-1 border-t border-stone-200 bg-stone-50/80 px-1.5 dark:border-stone-800 dark:bg-stone-950/30">
          <div class="inline-flex min-w-0 items-center gap-0.5">
            <label class={selector_label_class(@mode, "quick", @options_locked?)}>
              <input
                type="radio"
                name="chat[mode]"
                value="quick"
                checked={@mode == "quick"}
                class="sr-only"
                disabled={@options_locked?}
              />
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-3.5" />
              <span>Quick</span>
            </label>
            <label class={selector_label_class(@mode, "research", @options_locked?)}>
              <input
                type="radio"
                name="chat[mode]"
                value="research"
                checked={@mode == "research"}
                class="sr-only"
                disabled={@options_locked?}
              />
              <.icon name="hero-beaker" class="size-3.5" />
              <span>Research</span>
            </label>
            <label class={selector_label_class(@mode, "edit", @options_locked?)}>
              <input
                type="radio"
                name="chat[mode]"
                value="edit"
                checked={@mode == "edit"}
                class="sr-only"
                disabled={@options_locked?}
              />
              <.icon name="hero-pencil-square" class="size-3.5" />
              <span>Edit</span>
            </label>
          </div>

          <span class="min-w-0 flex-1"></span>
          <.selected_context_badge selected_id={@selected_id} />

          <label class="sr-only" for={"#{@id}-model-provider"}>Model</label>
          <select
            id={"#{@id}-model-provider"}
            name="chat[model_provider]"
            class="h-7 rounded-sm border border-stone-200 bg-white px-1.5 py-0 text-stone-700 outline-none focus:border-stone-400 focus:ring-0 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-200"
            disabled={@options_locked?}
          >
            <option
              :for={option <- Sheaf.LLM.assistant_model_options()}
              value={option.provider}
              selected={@model_provider == option.provider}
            >
              {option.label}
            </option>
          </select>

          <button
            type="submit"
            class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 disabled:cursor-not-allowed disabled:text-stone-300 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50 dark:disabled:text-stone-700"
            title="Send"
            aria-label="Send"
            disabled={@pending}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </div>
    </.form>
    """
  end

  attr :selected_id, :string, default: nil

  defp selected_context_badge(assigns) do
    ~H"""
    <span
      :if={is_binary(@selected_id) and @selected_id != ""}
      class="max-w-24 shrink-0 truncate border border-stone-300 bg-white px-1.5  text-stone-600 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-300"
      title={"Context ##{@selected_id}"}
    >
      {"##{@selected_id}"}
    </span>
    """
  end

  attr :item, :map, required: true
  attr :message_id, :string, required: true
  attr :titles, :map, default: %{}
  attr :block_ref_target, :any, default: nil
  attr :myself, :any, default: nil

  defp chat_item(%{item: %{kind: :message, message: message}} = assigns) do
    assigns =
      assigns
      |> assign(:message, message)
      |> assign(:message_index, Map.get(assigns.item, :message_index))

    ~H"""
    <.chat_message
      id={@message_id}
      message={@message}
      message_index={@message_index}
      titles={@titles}
      block_ref_target={@block_ref_target}
      myself={@myself}
    />
    """
  end

  defp chat_item(%{item: %{kind: :tools, messages: messages}} = assigns) do
    assigns = assign(assigns, :messages, messages)

    ~H"""
    <.activity_stack label="Assistant tool activity">
      <.tool_chip :for={message <- @messages} message={message} titles={@titles} />
    </.activity_stack>
    """
  end

  defp tool_chip(assigns) do
    assigns = assign(assigns, :tool_view, tool_view(assigns.message, assigns.titles))

    ~H"""
    <.activity_preview
      :if={@tool_view.body?}
      icon={@tool_view.icon}
      tone={@tool_view.tone}
      title={@tool_view.title}
      subtitle={@tool_view.subtitle}
      meta={@tool_view.meta}
      status={@tool_view.status_label}
      open={false}
    >
      <.tool_preview_body message={@message} tool_view={@tool_view} />
    </.activity_preview>
    <.activity_row
      :if={!@tool_view.body?}
      icon={@tool_view.icon}
      tone={@tool_view.tone}
      title={@tool_view.title}
      summary={@tool_view.subtitle}
      meta={@tool_view.meta}
      status={@tool_view.status_label}
    />
    """
  end

  attr :message, :map, required: true
  attr :tool_view, :map, required: true

  defp tool_preview_body(%{message: %{result: %ToolResults.ListDocuments{} = result}} = assigns) do
    assigns =
      assigns
      |> assign(:documents, Enum.take(result.documents, 8))
      |> assign(:remaining, max(length(result.documents) - 8, 0))

    ~H"""
    <div class="min-w-0">
      <.document_result_item :for={document <- @documents} document={document} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="documents" />
    </div>
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.Document{} = result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="min-w-0 px-2">
      <div class="text-stone-900 dark:text-stone-50">
        {@result.title}
      </div>
      <.outline_preview entries={@result.outline} />
    </div>
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.Blocks{} = result}} = assigns) do
    assigns =
      assigns
      |> assign(:blocks, result.blocks |> Enum.filter(&informative_block?/1) |> Enum.take(6))
      |> assign(:remaining, max(length(result.blocks) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.block_result_item :for={block <- @blocks} block={block} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="blocks" />
    </div>
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.Block{} = result}} = assigns) do
    assigns = assign(assigns, :block, result)

    ~H"""
    <.block_result_item block={@block} />
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.SearchResults{} = result}} = assigns) do
    assigns =
      assigns
      |> assign(:exact_results, result.exact_results)
      |> assign(:approximate_results, result.approximate_results)
      |> assign(:query, tool_arg(Map.get(assigns.message, :input, %{}), :query) || "")

    ~H"""
    <div class="min-w-0">
      <.search_result_group label="Exact matches" hits={@exact_results} query={@query} />
      <.search_result_group label="Related passages" hits={@approximate_results} query={@query} />
    </div>
    """
  end

  defp tool_preview_body(
         %{message: %{result: %ToolResults.ListSpreadsheets{} = result}} = assigns
       ) do
    assigns =
      assigns
      |> assign(:spreadsheets, Enum.take(result.spreadsheets, 6))
      |> assign(:remaining, max(length(result.spreadsheets) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.spreadsheet_result_item :for={spreadsheet <- @spreadsheets} spreadsheet={spreadsheet} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="spreadsheets" />
    </div>
    """
  end

  defp tool_preview_body(
         %{message: %{result: %ToolResults.SpreadsheetSearch{} = result}} = assigns
       ) do
    assigns =
      assigns
      |> assign(:hits, Enum.take(result.hits, 6))
      |> assign(:remaining, max(length(result.hits) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.spreadsheet_hit_item :for={hit <- @hits} hit={hit} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="hits" />
    </div>
    """
  end

  defp tool_preview_body(
         %{message: %{result: %ToolResults.SpreadsheetQuery{} = result}} = assigns
       ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <.query_result_preview result={@result} result_id={@result.result_id} />
    """
  end

  defp tool_preview_body(
         %{message: %{result: %ToolResults.SpreadsheetQueryResultPage{} = result}} = assigns
       ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <.query_result_preview result={@result} result_id={@result.id} />
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.ParagraphTags{} = result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="text-stone-600 dark:text-stone-300">
      <div>
        <span class="text-stone-400 dark:text-stone-500">Tags</span> {Enum.join(@result.tags, ", ")}
      </div>
      <div>
        <span class="text-stone-400 dark:text-stone-500">Blocks</span> {Enum.map_join(
          @result.block_ids,
          ", ",
          &"##{&1}"
        )}
      </div>
    </div>
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.BlockEdit{} = result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class=" px-2">
      <div class="flex flex-wrap gap-2 font-micro text-stone-500 dark:text-stone-400">
        <span :if={@result.document_id} class="border border-stone-200 px-1 dark:border-stone-800">
          doc #{@result.document_id}
        </span>
        <span :if={@result.block_id} class="border border-stone-200 px-1 dark:border-stone-800">
          block #{@result.block_id}
        </span>
        <span :if={@result.target_id} class="border border-stone-200 px-1 dark:border-stone-800">
          target #{@result.target_id} {@result.position}
        </span>
      </div>
      <.edit_text_preview before_text={@result.previous_text} after_text={@result.text} />
    </div>
    """
  end

  defp tool_preview_body(
         %{message: %{result: %ToolResults.SearchIndexUpdate{} = result}} = assigns
       ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="grid grid-cols-2 gap-x-3 gap-y-1 font-sans text-stone-600 dark:text-stone-300">
      <span class="text-stone-400 dark:text-stone-500">Requested</span>
      <span>{Enum.map_join(@result.block_ids, ", ", &"##{&1}")}</span>
      <span class="text-stone-400 dark:text-stone-500">Affected</span>
      <span>{Enum.map_join(@result.affected_blocks, ", ", &"##{&1}")}</span>
      <span class="text-stone-400 dark:text-stone-500">Embeddings</span>
      <span>{@result.embedding_embedded_count}/{@result.embedding_target_count} refreshed</span>
      <span class="text-stone-400 dark:text-stone-500">Search rows</span>
      <span>{@result.search_count}</span>
    </div>
    """
  end

  defp tool_preview_body(%{message: %{result: %ToolResults.Note{} = result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <a href={~p"/#{@result.id}"} class="text-stone-700 hover:underline dark:text-stone-200">
      Open note #{@result.id}
    </a>
    """
  end

  defp tool_preview_body(assigns) do
    ~H"""
    <p class="px-2 text-stone-500 dark:text-stone-400">
      {@tool_view.summary || @tool_view.detail || "Waiting for result"}
    </p>
    """
  end

  attr :document, :any, required: true

  defp document_result_item(assigns) do
    assigns = assign(assigns, :entry, tool_document_entry(assigns.document))

    ~H"""
    <div class="px-2 last:border-b-0 dark:border-stone-900">
      <.document_title_line
        document={@entry}
        link_title={false}
        show_status_pills={false}
        class="flex min-w-0 items-baseline gap-2 font-sans"
        title_class="min-w-0 flex-1 truncate text-stone-900 dark:text-stone-50"
      />
      <.document_metadata_lines
        document={@entry}
        show_id={true}
        show_kind={true}
        show_status={true}
        show_publisher={false}
        subline_class="flex min-w-0 items-baseline gap-2 truncate font-sans text-stone-500 dark:text-stone-400"
        detail_class="flex min-w-0 items-baseline gap-2 truncate font-sans text-stone-500 dark:text-stone-400"
        authors_class="min-w-0 truncate text-stone-500 dark:text-stone-400"
        id_class="shrink-0 font-micro tabular-nums"
        kind_class="shrink-0"
        status_class="shrink-0 font-micro text-sky-700 dark:text-sky-300"
      />
    </div>
    """
  end

  attr :entries, :list, default: []

  defp outline_preview(assigns) do
    ~H"""
    <ol class="mt-1 font-sans">
      <li :for={entry <- @entries} class="text-stone-600 dark:text-stone-300">
        <span
          :if={Map.get(entry, :number)}
          class="mr-1 tabular-nums text-stone-400 dark:text-stone-500"
        >
          {Map.get(entry, :number)}
        </span>
        <span>{Map.get(entry, :title)}</span>
        <.outline_preview
          :if={Map.get(entry, :children, []) != []}
          entries={Map.get(entry, :children, [])}
        />
      </li>
    </ol>
    """
  end

  attr :block, :any, required: true

  defp block_result_item(assigns) do
    ~H"""
    <section class="min-w-0 border-b border-stone-100 px-2 last:border-b-0 dark:border-stone-900">
      <div class="flex flex-wrap items-baseline gap-x-2 font-sans text-stone-500 dark:text-stone-400">
        <span
          :if={Map.get(@block, :id)}
          class="font-micro tabular-nums text-stone-500 dark:text-stone-400"
        >
          #{Map.get(@block, :id)}
        </span>
        <span :if={Map.get(@block, :document_id)} class="font-micro tabular-nums">
          doc #{Map.get(@block, :document_id)}
        </span>
        <span :if={block_type_label(@block) != ""}>{block_type_label(@block)}</span>
        <span :if={source_label(Map.get(@block, :source)) != ""}>
          {source_label(Map.get(@block, :source))}
        </span>
      </div>
      <div :if={block_heading(@block) != ""} class="mt-1  text-stone-900 dark:text-stone-50">
        {block_heading(@block)}
      </div>
      <p
        :if={block_text(@block) != ""}
        class="mt-1 whitespace-pre-wrap text-stone-800 dark:text-stone-100"
      >
        {block_text(@block)}
      </p>
      <ol :if={Map.get(@block, :children, []) != []} class="mt-1 font-sans">
        <li
          :for={child <- Map.get(@block, :children, [])}
          :if={informative_block?(child)}
          class="text-stone-600 dark:text-stone-300"
        >
          <span class="font-micro text-stone-400 dark:text-stone-500">#{Map.get(child, :id)}</span>
          {block_heading(child) || block_text(child)}
        </li>
      </ol>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :hits, :list, default: []
  attr :query, :string, default: ""

  defp search_result_group(assigns) do
    assigns =
      assigns
      |> assign(:visible_hits, Enum.take(assigns.hits, 5))
      |> assign(:remaining, max(length(assigns.hits) - 5, 0))

    ~H"""
    <section :if={@hits != []} class="last:[&>*:last-child]:after:hidden">
      <.tool_section_label label={@label} count={length(@hits)} />
      <div>
        <.search_hit_item :for={hit <- @visible_hits} hit={hit} query={@query} />
        <.more_result_row :if={@remaining > 0} count={@remaining} noun="passages" />
      </div>
    </section>
    """
  end

  attr :count, :integer, required: true
  attr :noun, :string, required: true

  defp more_result_row(assigns) do
    ~H"""
    <div class="relative px-2 font-sans text-stone-500  dark:bg-stone-950/30 dark:text-stone-400 dark:after:bg-stone-800">
      +{@count} more {@noun}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, default: nil

  defp tool_section_label(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 flex items-center justify-between gap-2 bg-stone-50/90 px-2 font-sans  uppercase text-stone-400 after:absolute after:inset-x-0 after:bottom-0 after:h-px after:bg-stone-200 dark:bg-stone-900/95 dark:text-stone-500 dark:after:bg-stone-800 relative">
      <span>{@label}</span>
      <span :if={is_integer(@count)} class="shrink-0 tabular-nums">{@count}</span>
    </div>
    """
  end

  attr :hit, :any, required: true
  attr :query, :string, default: ""

  defp search_hit_item(assigns) do
    assigns =
      assigns
      |> assign(:block_id, value_at(assigns.hit, :block_id))
      |> assign(:document_title, value_at(assigns.hit, :document_title))
      |> assign(:document_status, value_at(assigns.hit, :document_status))
      |> assign(:context, search_hit_context(assigns.hit))
      |> assign(:score, search_hit_score(assigns.hit))
      |> assign(
        :preview_parts,
        value_at(assigns.hit, :text)
        |> search_display_text()
        |> search_excerpt(assigns.query, 90)
        |> highlighted_search_parts(assigns.query)
      )
      |> assign(
        :parts,
        assigns.hit
        |> value_at(:text)
        |> search_display_text()
        |> highlighted_search_parts(assigns.query)
      )

    ~H"""
    <details class="group relative bg-white after:absolute after:inset-x-0 after:bottom-0 after:h-px after:bg-stone-200 last:after:hidden open:bg-stone-50 dark:bg-stone-950/30 dark:after:bg-stone-800 dark:open:bg-stone-900/80">
      <summary class="flex cursor-pointer list-none gap-x-2 px-2 font-sans transition-colors hover:bg-stone-50 dark:hover:bg-stone-900/70 [&::-webkit-details-marker]:hidden">
        <span class="min-w-0 flex-1">
          <span class="flex min-w-0 items-baseline gap-x-2 overflow-hidden font-sans text-stone-500 dark:text-stone-400">
            <span
              :if={@block_id}
              class="shrink-0 font-micro tabular-nums text-stone-600 dark:text-stone-300"
            >
              #{@block_id}
            </span>
            <span :if={@document_title} class="min-w-0 truncate  text-stone-700 dark:text-stone-200">
              {@document_title}
            </span>
            <span :if={@document_status} class={search_status_class(@document_status)}>
              {@document_status}
            </span>
          </span>
          <span class="block min-w-0 truncate font-sans text-stone-900 dark:text-stone-100">
            <span :for={{part, highlighted?} <- @preview_parts}>
              <mark
                :if={highlighted?}
                class="bg-amber-200/60 px-0.5 text-inherit dark:bg-amber-400/25"
              >
                {part}
              </mark>
              <span :if={!highlighted?}>{part}</span>
            </span>
          </span>
        </span>
        <span class="w-10 shrink-0 self-start text-right font-sans tabular-nums text-stone-400 dark:text-stone-500">
          {@score}
        </span>
      </summary>
      <div class="relative px-2 before:absolute before:inset-x-0 before:top-0 before:h-px before:bg-stone-200 dark:before:bg-stone-800">
        <div
          :if={present_text?(@context)}
          class="h-5 truncate font-sans text-stone-500 dark:text-stone-400"
        >
          {@context}
        </div>
        <p :if={@parts != []} class="max-h-24 overflow-y-auto text-stone-800 dark:text-stone-100">
          <span :for={{part, highlighted?} <- @parts}>
            <mark
              :if={highlighted?}
              class="bg-amber-200/60 px-0.5 text-inherit dark:bg-amber-400/25"
            >
              {part}
            </mark>
            <span :if={!highlighted?}>{part}</span>
          </span>
        </p>
      </div>
    </details>
    """
  end

  attr :spreadsheet, :any, required: true

  defp spreadsheet_result_item(assigns) do
    ~H"""
    <section class="border-b border-stone-100 px-2 last:border-b-0 dark:border-stone-900">
      <div class=" text-stone-900 dark:text-stone-50">
        {Map.get(@spreadsheet, :title)}
      </div>
      <ol class="mt-1 font-sans text-stone-600 dark:text-stone-300">
        <li :for={sheet <- Map.get(@spreadsheet, :sheets, [])}>
          <span class="">{Map.get(sheet, :name)}</span>
          <span class="text-stone-500 dark:text-stone-400">
            {Map.get(sheet, :row_count)} rows x {Map.get(sheet, :col_count)} columns
          </span>
        </li>
      </ol>
    </section>
    """
  end

  attr :hit, :any, required: true

  defp spreadsheet_hit_item(assigns) do
    ~H"""
    <article class="border-l border-stone-200 px-2 dark:border-stone-800">
      <div class="font-sans text-stone-500 dark:text-stone-400">
        {Map.get(@hit, :document_title) || Map.get(@hit, :document_id)}
      </div>
      <p class="mt-0.5 text-stone-800 dark:text-stone-100">
        {Map.get(@hit, :text) || Map.get(@hit, :match)}
      </p>
    </article>
    """
  end

  attr :result, :any, required: true
  attr :result_id, :string, default: nil

  defp query_result_preview(assigns) do
    ~H"""
    <div class="px-2">
      <pre
        :if={Map.get(@result, :sql)}
        class="max-h-24 overflow-auto border border-stone-100 bg-stone-50 text-stone-700 dark:border-stone-800 dark:bg-stone-900 dark:text-stone-200"
      ><code>{Map.get(@result, :sql)}</code></pre>
      <div class="overflow-x-auto">
        <table class="min-w-full border-collapse font-sans">
          <thead>
            <tr class="border-b border-stone-200 text-left text-stone-500 dark:border-stone-800 dark:text-stone-400">
              <th :for={column <- Map.get(@result, :columns, [])} class="px-1 ">
                {column}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- Map.get(@result, :rows, [])}
              class="border-b border-stone-100 last:border-b-0 dark:border-stone-900"
            >
              <td
                :for={column <- Map.get(@result, :columns, [])}
                class="px-1 text-stone-700 dark:text-stone-200"
              >
                {cell_value(row, column)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <a
        :if={@result_id}
        href={~p"/#{@result_id}"}
        class="inline-block text-stone-500 hover:underline dark:text-stone-400"
      >
        Open saved result #{@result_id}
      </a>
    </div>
    """
  end

  attr :before_text, :string, default: nil
  attr :after_text, :string, default: nil

  defp edit_text_preview(assigns) do
    ~H"""
    <div class="grid gap-1">
      <p
        :if={present_text?(@before_text)}
        class="border-l border-red-300 bg-red-50/50 px-1.5 text-red-800 dark:border-red-900 dark:bg-red-950/20 dark:text-red-200"
      >
        {@before_text}
      </p>
      <p
        :if={present_text?(@after_text)}
        class="border-l border-emerald-400 bg-emerald-50/50 px-1.5 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/20 dark:text-emerald-100"
      >
        {@after_text}
      </p>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :id, :string, required: true
  attr :message_index, :integer, default: nil
  attr :titles, :map, default: %{}
  attr :block_ref_target, :any, default: nil
  attr :myself, :any, default: nil

  defp chat_message(%{message: %{role: :user}} = assigns) do
    ~H"""
    <div class=" border-l-6 border-sky-200 px-3 py-2 font-text text-stone-950 dark:border-sky-900/70 dark:bg-sky-950/30 dark:text-stone-50">
      <AssistantMarkdownComponents.markdown
        text={@message.text}
        block_ref_target={@block_ref_target}
        resolve_block_previews={false}
      />
    </div>
    """
  end

  defp chat_message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="group relative  border-l-6 border-stone-200 px-3 py-2 text-stone-900 dark:border-sky-900/70 dark:bg-sky-950/30 dark:text-stone-50"
      phx-hook="AssistantTypeWriter"
      data-typewriter-streaming={Map.get(@message, :streaming?, false)}
    >
      <div class="assistant-prose">
        <AssistantMarkdownComponents.markdown
          text={@message.text}
          block_ref_target={@block_ref_target}
          resolve_block_previews={false}
        />
      </div>
      <div class="flex items-center justify-end gap-1 font-sans text-xs">
        <.link
          :if={promoted_note_id(@message)}
          navigate={~p"/#{promoted_note_id(@message)}"}
          class="inline-flex items-center gap-1 rounded-sm px-1.5 py-1 text-stone-500 hover:bg-stone-100 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
        >
          <.icon name="hero-document-text" class="size-3.5" />
          <span>Note</span>
        </.link>
        <button
          :if={
            !Map.get(@message, :streaming?, false) and is_integer(@message_index) and
              is_nil(promoted_note_id(@message))
          }
          type="button"
          phx-click="promote_note"
          phx-value-index={@message_index}
          phx-target={@myself}
          class="inline-flex items-center gap-1 rounded-sm px-1.5 text-stone-400 opacity-0 transition hover:bg-stone-100 hover:text-stone-950 group-hover:opacity-100 focus:opacity-100 dark:text-stone-500 dark:hover:bg-stone-800 dark:hover:text-stone-50"
          title="Promote response to note"
          aria-label="Promote response to note"
        >
          <.icon name="hero-document-plus" class="size-3.5" />
          <span>Note</span>
        </button>
      </div>
    </div>
    """
  end

  defp chat_message(
         %{message: %{role: :tool, tool: "present_spreadsheet_query_result", result: result}} =
           assigns
       ) do
    assigns =
      assigns
      |> assign(:result, result)
      |> assign(:table, presented_table(result))
      |> assign(:tool_view, tool_view(assigns.message, assigns.titles))

    ~H"""
    <article class="overflow-hidden border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
      <header class="flex min-w-0 items-start justify-between gap-2 border-b border-stone-200 bg-stone-50 px-2 dark:border-stone-800 dark:bg-stone-950/40">
        <div class="min-w-0">
          <p class="font-sans font-semibold uppercase text-stone-500 dark:text-stone-400">
            Spreadsheet query result
            <span class={["ml-1 font-normal normal-case", @tool_view.status_class]}>
              {@tool_view.detail}
            </span>
          </p>
          <h3 class="font-semibold text-stone-950 dark:text-stone-50">
            {@table.title}
          </h3>
          <p
            :if={@table.description != ""}
            class="text-stone-600 dark:text-stone-300"
          >
            {@table.description}
          </p>
        </div>
        <a
          :if={@table.result_path}
          href={@table.result_path}
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
          title="Open result"
          aria-label="Open result"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
      </header>
      <div class="overflow-x-auto px-2">
        <DataTableComponents.data_table columns={@table.columns} rows={@table.rows} />
      </div>
      <footer class="border-t border-stone-200 px-2 font-sans text-stone-500 dark:border-stone-800 dark:text-stone-400">
        Showing {@table.returned} {@table.row_label} from offset {@table.offset} of {@table.row_count}
      </footer>
    </article>
    """
  end

  defp chat_message(%{message: %{role: :tool, tool: "write_note", input: input}} = assigns) do
    assigns =
      assigns
      |> assign(:tool_view, tool_view(assigns.message, assigns.titles))
      |> assign(:note_view, note_view(input))

    ~H"""
    <div class="px-1">
      <.activity_panel
        tone={:note}
        icon="hero-document-text"
        title="Research note"
        detail={@tool_view.detail}
      >
        <h3
          :if={@note_view.title != ""}
          class="mb-2 font-semibold leading-snug text-stone-950 dark:text-stone-50"
        >
          {@note_view.title}
        </h3>
        <div
          :if={@note_view.text != ""}
          class="assistant-prose max-h-80 overflow-y-auto break-words pr-1 text-stone-800 dark:text-stone-100"
        >
          <AssistantMarkdownComponents.markdown
            text={@note_view.text}
            block_ref_target={@block_ref_target}
          />
        </div>
        <p :if={@note_view.text == ""} class="text-stone-500 dark:text-stone-400">
          The assistant is preparing a note.
        </p>
      </.activity_panel>
    </div>
    """
  end

  defp chat_message(%{message: %{role: :status}} = assigns) do
    ~H"""
    <div class="px-1 font-sans italic text-stone-500 dark:text-stone-400">
      {@message.text}
    </div>
    """
  end

  defp chat_message(%{message: %{role: :error}} = assigns) do
    ~H"""
    <div class="rounded-sm bg-red-50/70 px-3 text-red-800 dark:bg-red-950/30 dark:text-red-300">
      {@message.text}
    </div>
    """
  end

  defp chat_message(assigns), do: ~H""

  defp tool_view(%{tool: "list_documents"} = message, _titles) do
    tool_phrase("Listing documents", message)
  end

  defp tool_view(%{tool: "get_document", input: input} = message, titles) do
    id = tool_arg(input, :id)
    title = title_or_id(id, titles)
    target = if title == "", do: "Reading document outline", else: "Reading #{title}'s outline"

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "read", input: input} = message, _titles) do
    block_ids = tool_blocks(input)
    expanded? = tool_arg(input, :expand) in [true, "true"]

    target =
      case block_ids do
        [block_id] ->
          if expanded?,
            do: "Reading expanded block #{block_id}",
            else: "Reading block #{block_id}"

        ids when ids != [] ->
          if expanded?,
            do: "Reading #{length(ids)} expanded blocks",
            else: "Reading #{length(ids)} blocks"

        _ids ->
          "Reading a block"
      end

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "search_text", input: input} = message, titles) do
    query = tool_arg(input, :query) || ""
    scope = tool_arg(input, :document_id)
    scope = if scope, do: title_or_id(scope, titles), else: "the corpus"
    target = query

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "list_spreadsheets", input: input} = message, _titles) do
    query = input |> tool_arg(:query) |> note_text_value()

    target =
      if query == "",
        do: "Listing spreadsheets",
        else: "Listing spreadsheets matching “#{query}”"

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "search_spreadsheets", input: input} = message, _titles) do
    query = input |> tool_arg(:query) |> note_text_value()

    target =
      if query == "",
        do: "Searching spreadsheet rows",
        else: "Searching spreadsheet rows matching “#{query}”"

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "write_note", input: input} = message, _titles) do
    title = tool_arg(input, :title) || tool_arg(input, :text)

    note =
      if is_binary(title) and String.trim(title) != "",
        do: "“#{title}”",
        else: "research note"

    tool_phrase("save #{note}", message)
  end

  defp tool_view(%{tool: "tag_paragraphs", input: input} = message, _titles) do
    block_count = input |> tool_blocks() |> length()
    tags = input |> tool_arg(:tags) |> List.wrap() |> Enum.filter(&is_binary/1)

    target =
      case {block_count, tags} do
        {1, []} -> "Tagging a paragraph"
        {1, tags} -> "Tagging a paragraph as #{Enum.join(tags, ", ")}"
        {count, []} when count > 1 -> "Tagging #{count} paragraphs"
        {count, tags} when count > 1 -> "Tagging #{count} paragraphs as #{Enum.join(tags, ", ")}"
        _ -> "Tagging paragraphs"
      end

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "update_block_text", input: input} = message, _titles) do
    block = tool_arg(input, :block)

    target =
      if is_binary(block) and block != "",
        do: "Updating block #{block}",
        else: "Updating a block"

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "move_block", input: input} = message, _titles) do
    block = tool_arg(input, :block)
    target = tool_arg(input, :target)
    position = tool_arg(input, :position)

    target =
      if is_binary(block) and is_binary(target) and is_binary(position) do
        "Moving #{block} #{position} #{target}"
      else
        "Moving a block"
      end

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "insert_paragraph", input: input} = message, _titles) do
    target_id = tool_arg(input, :target)
    position = tool_arg(input, :position)

    target =
      if is_binary(target_id) and is_binary(position) do
        "Inserting a paragraph #{position} #{target_id}"
      else
        "Inserting a paragraph"
      end

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "update_search_index", input: input} = message, _titles) do
    block_count = input |> tool_blocks() |> length()

    target =
      case block_count do
        1 -> "Updating search indexes for 1 block"
        count when count > 1 -> "Updating search indexes for #{count} blocks"
        _ -> "Updating search indexes"
      end

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "query_spreadsheets", input: input} = message, _titles) do
    intent = input |> tool_arg(:intent) |> note_text_value()
    target = if intent == "", do: "Querying spreadsheets", else: intent

    tool_phrase(target, message)
  end

  defp tool_view(%{tool: "read_spreadsheet_query_result", input: input} = message, _titles) do
    offset = tool_arg(input, :offset)
    limit = tool_arg(input, :limit)

    range =
      case {offset, limit} do
        {nil, nil} -> "rows"
        {offset, nil} -> "rows from #{offset}"
        {nil, limit} -> "first #{limit} rows"
        {offset, limit} -> "rows #{offset}–#{offset + limit}"
      end

    tool_phrase("Reading #{range}", message)
  end

  defp tool_view(%{tool: tool} = message, _titles) when is_binary(tool) do
    tool_phrase("Running #{String.replace(tool, "_", " ")}", message)
  end

  defp tool_view(message, _titles), do: tool_phrase("Running tool", message)

  defp tool_document_entry(document) do
    %{
      id: Map.get(document, :id),
      kind: Map.get(document, :kind),
      path: nil,
      title: Map.get(document, :title),
      excluded?: false,
      cited?: Map.get(document, :cited?, false),
      has_document?: Map.get(document, :has_document?, true),
      metadata: %{
        authors: Map.get(document, :authors, []),
        year: Map.get(document, :year),
        kind: Map.get(document, :metadata_kind) || Map.get(document, :kind),
        page_count: Map.get(document, :page_count),
        status: Map.get(document, :status)
      }
    }
  end

  defp block_type_label(block) do
    block
    |> Map.get(:type)
    |> case do
      nil -> ""
      type -> type |> to_string() |> clean_machine_label()
    end
  end

  defp block_heading(block) do
    cond do
      present_text?(Map.get(block, :title)) -> Map.get(block, :title)
      Map.get(block, :ancestry, []) != [] -> block_context_line(Map.get(block, :ancestry, []))
      true -> ""
    end
  end

  defp block_context_line(context) do
    context
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :title) || Map.get(&1, :id)))
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" / ")
  end

  defp block_text(block), do: Map.get(block, :text) |> text_value()

  defp informative_block?(block) when is_map(block) do
    present_text?(Map.get(block, :title)) or present_text?(Map.get(block, :text)) or
      present_text?(Map.get(block, :preview))
  end

  defp informative_block?(_block), do: false

  defp clean_machine_label("NORMAL_TEXT"), do: ""
  defp clean_machine_label(value), do: value |> String.replace("_", " ") |> String.downcase()

  defp source_label(source) when is_map(source) do
    [value_at(source, :type), source_page_label(value_at(source, :page))]
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" ")
  end

  defp source_label(_source), do: ""

  defp source_page_label(page) when page in [nil, "", "nil"], do: nil
  defp source_page_label(page), do: "p. #{page}"

  defp search_hit_context(hit) do
    [
      search_kind_label(value_at(hit, :kind)),
      source_page_label(value_at(hit, :source_page)),
      search_coding_label(value_at(hit, :coding)),
      search_outline_label(value_at(hit, :context) || [])
    ]
    |> Enum.reject(&(!present_text?(&1)))
    |> Enum.join(" · ")
  end

  defp search_kind_label(:extracted), do: "source"
  defp search_kind_label(:paragraph), do: "paragraph"
  defp search_kind_label(:row), do: "coded row"
  defp search_kind_label(nil), do: nil

  defp search_kind_label(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
  end

  defp search_coding_label(coding) when is_map(coding) do
    [
      row_label(value_at(coding, :row)),
      value_at(coding, :source),
      value_at(coding, :category_title)
    ]
    |> Enum.reject(&(!present_text?(&1)))
    |> Enum.join(" · ")
  end

  defp search_coding_label(_coding), do: nil

  defp search_outline_label(context) do
    context
    |> List.wrap()
    |> Enum.map(fn entry ->
      if is_map(entry), do: value_at(entry, :title) || value_at(entry, :id), else: nil
    end)
    |> Enum.filter(&present_text?/1)
    |> Enum.take(-2)
    |> Enum.join(" / ")
  end

  defp search_hit_score(hit) do
    case value_at(hit, :score) do
      score when is_float(score) -> "#{round(score * 100)}%"
      score when is_integer(score) -> "#{score}"
      _score -> ""
    end
  end

  defp search_status_class("draft") do
    "shrink-0 font-micro text-sky-700 dark:text-sky-300"
  end

  defp search_status_class("mikael") do
    "shrink-0 font-micro text-emerald-700 dark:text-emerald-300"
  end

  defp search_status_class(_status) do
    "shrink-0 font-micro text-stone-500 dark:text-stone-400"
  end

  defp search_display_text(text) do
    text
    |> text_value()
    |> String.replace(~r/\s+/, " ")
  end

  defp search_excerpt(text, query, radius) do
    text = text_value(text)
    query = text_value(query)

    cond do
      text == "" ->
        ""

      query == "" ->
        String.slice(text, 0, radius * 2)

      true ->
        haystack = String.downcase(text)
        needle = String.downcase(query)

        case :binary.match(haystack, needle) do
          {index, length} ->
            start = max(index - radius, 0)
            finish = min(index + length + radius, String.length(text))
            prefix = if start > 0, do: "... ", else: ""
            suffix = if finish < String.length(text), do: " ...", else: ""
            prefix <> String.slice(text, start, finish - start) <> suffix

          :nomatch ->
            String.slice(text, 0, radius * 2)
        end
    end
  end

  defp highlighted_search_parts(text, query) do
    text = text_value(text)
    query = text_value(query)

    cond do
      text == "" ->
        []

      query == "" ->
        [{text, false}]

      true ->
        split_highlighted_text(text, query)
    end
  end

  defp split_highlighted_text(text, query) do
    pattern = Regex.compile!(Regex.escape(query), "iu")
    normalized_query = String.downcase(query)

    pattern
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      {part, String.downcase(part) == normalized_query}
    end)
  end

  defp row_label(nil), do: nil
  defp row_label(row), do: "row #{row}"

  defp value_at(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      "nil" -> nil
      value -> value
    end
  end

  defp value_at(_value, _key), do: nil

  defp cell_value(row, column) when is_map(row) do
    value = Map.get(row, column) || Map.get(row, to_string(column))
    if is_nil(value), do: "", else: to_string(value)
  end

  defp cell_value(_row, _column), do: ""

  defp present_text?(value) when is_binary(value), do: text_value(value) != ""
  defp present_text?(nil), do: false
  defp present_text?(value), do: value |> to_string() |> text_value() != ""

  defp text_value(value) when is_binary(value) do
    value = String.trim(value)
    if String.downcase(value) == "nil", do: "", else: value
  end

  defp text_value(_value), do: ""

  defp tool_phrase(phrase, message) do
    status = Map.get(message, :status)
    summary = tool_summary(message)

    %{
      title: phrase || "",
      subtitle: tool_subtitle(message),
      meta: tool_meta(message),
      body?: tool_body?(message),
      detail: tool_detail(message),
      status_class: tool_phrase_class(status),
      status_label: tool_status_label(status, summary),
      summary: summary,
      icon: tool_icon(Map.get(message, :tool)),
      tone: tool_tone(status)
    }
  end

  defp tool_detail(%{status: :pending}), do: "Working…"
  defp tool_detail(%{status: :ok, summary: summary}) when summary in [nil, ""], do: "done"
  defp tool_detail(%{status: :ok, summary: summary}), do: detail_text(summary)
  defp tool_detail(%{status: :error, summary: summary}) when summary in [nil, ""], do: "error"
  defp tool_detail(%{status: :error, summary: summary}), do: detail_text(summary)
  defp tool_detail(_), do: ""

  defp detail_text(summary), do: summary

  defp tool_body?(%{status: :pending}), do: false
  defp tool_body?(%{status: :error}), do: false
  defp tool_body?(%{result: %ToolResults.SearchIndexUpdate{}}), do: false
  defp tool_body?(%{result: %ToolResults.ParagraphTags{}}), do: false
  defp tool_body?(%{result: %ToolResults.Note{}}), do: false
  defp tool_body?(%{result: %ToolResults.Blocks{}}), do: false
  defp tool_body?(%{result: %ToolResults.Block{}}), do: false
  defp tool_body?(%{result: nil}), do: false
  defp tool_body?(%{result: _result}), do: true
  defp tool_body?(_message), do: false

  defp tool_meta(%{result: %ToolResults.SearchIndexUpdate{} = result}) do
    [
      count_label("requested", length(result.block_ids)),
      count_label("affected", length(result.affected_blocks)),
      "embeddings #{result.embedding_embedded_count}/#{result.embedding_target_count}",
      "search rows #{result.search_count}"
    ]
  end

  defp tool_meta(%{result: %ToolResults.ListDocuments{} = result}) do
    [
      count_label("documents", length(result.documents)),
      document_status_count(result.documents, "draft"),
      document_status_count(result.documents, "mikael")
    ]
    |> Enum.reject(&(&1 == ""))
  end

  defp tool_meta(%{result: %ToolResults.Document{} = result}) do
    [count_label("outline rows", outline_count(result.outline))]
  end

  defp tool_meta(%{result: %ToolResults.Blocks{} = result}) do
    result.blocks |> Enum.map(&block_type_label/1)
  end

  defp tool_meta(%{result: %ToolResults.Block{} = result}) do
    [block_type_label(result)]
  end

  defp tool_meta(%{result: %ToolResults.SearchResults{} = result}) do
    [
      count_label("hits", length(result.exact_results) + length(result.approximate_results)),
    ]
  end

  defp tool_meta(%{result: %ToolResults.ListSpreadsheets{} = result}) do
    [
      count_label("spreadsheets", result.returned_spreadsheets),
      count_label("sheets", result.returned_sheets)
    ]
  end

  defp tool_meta(%{result: %ToolResults.SpreadsheetSearch{} = result}) do
    [count_label("hits", length(result.hits))]
  end

  defp tool_meta(%{result: %ToolResults.SpreadsheetQuery{} = result}) do
    [
      count_label("rows", length(result.rows)),
      "of #{result.row_count}"
    ]
  end

  defp tool_meta(%{result: %ToolResults.SpreadsheetQueryResultPage{} = result}) do
    [
      count_label("rows", length(result.rows)),
      "offset #{result.offset}",
      "of #{result.row_count}"
    ]
  end

  defp tool_meta(%{result: %ToolResults.ParagraphTags{} = result}) do
    [
      count_label("blocks", length(result.block_ids)),
      count_label("tags", length(result.tags)),
      Enum.join(result.tags, ", ")
    ]
    |> Enum.reject(&(&1 == ""))
  end

  defp tool_meta(%{result: %ToolResults.Note{id: id}}) when is_binary(id), do: ["note #{id}"]
  defp tool_meta(_message), do: []

  defp document_status_count(documents, status) do
    count = Enum.count(documents, &(Map.get(&1, :status) == status))
    if count == 0, do: "", else: count_label(status, count)
  end

  defp outline_count(entries) do
    entries
    |> List.wrap()
    |> Enum.reduce(0, fn entry, count ->
      count + 1 + outline_count(Map.get(entry, :children, []))
    end)
  end

  defp count_label(label, 1), do: "1 #{label}"
  defp count_label(label, count), do: "#{count} #{label}"

  defp tool_subtitle(%{status: :pending}), do: "Waiting for result"
  defp tool_subtitle(%{result: result}) when not is_nil(result), do: ""
  defp tool_subtitle(%{summary: summary}) when summary not in [nil, ""], do: detail_text(summary)
  defp tool_subtitle(_message), do: ""

  defp tool_summary(%{status: status, summary: summary})
       when status in [:ok, :error] and summary not in [nil, ""] do
    detail_text(summary)
  end

  defp tool_summary(_message), do: ""

  defp tool_status_label(:pending, _summary), do: "working"
  defp tool_status_label(:error, _summary), do: "error"
  defp tool_status_label(:ok, _summary), do: ""
  defp tool_status_label(_status, _summary), do: ""

  defp tool_tone(:pending), do: :pending
  defp tool_tone(:error), do: :danger
  defp tool_tone(_status), do: :default

  defp tool_icon("list_documents"), do: "hero-document-duplicate"
  defp tool_icon("get_document"), do: "hero-document-text"
  defp tool_icon("read"), do: "hero-book-open"
  defp tool_icon("search_text"), do: "hero-magnifying-glass"
  defp tool_icon("list_spreadsheets"), do: "hero-table-cells"
  defp tool_icon("search_spreadsheets"), do: "hero-magnifying-glass"
  defp tool_icon("query_spreadsheets"), do: "hero-table-cells"
  defp tool_icon("read_spreadsheet_query_result"), do: "hero-table-cells"
  defp tool_icon("present_spreadsheet_query_result"), do: "hero-table-cells"
  defp tool_icon("write_note"), do: "hero-document-text"
  defp tool_icon("tag_paragraphs"), do: "hero-tag"
  defp tool_icon("update_block_text"), do: "hero-pencil-square"
  defp tool_icon("move_block"), do: "hero-arrows-up-down"
  defp tool_icon("insert_paragraph"), do: "hero-plus"
  defp tool_icon("delete_block"), do: "hero-trash"
  defp tool_icon("update_search_index"), do: "hero-arrow-path"
  defp tool_icon(_tool), do: "hero-wrench-screwdriver"

  defp tool_phrase_class(:error), do: "text-red-700 dark:text-red-300"
  defp tool_phrase_class(_), do: ""

  defp title_or_id(nil, _titles), do: ""

  defp title_or_id(id, titles) do
    case Map.get(titles, id) do
      nil -> "##{id}"
      title -> title
    end
  end

  defp tool_arg(input, key) when is_map(input) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  defp tool_arg(_, _), do: nil

  defp presented_table(%PresentedSpreadsheetQueryResult{} = result) do
    labels = presented_column_labels(result.columns, result.column_specs)

    %{
      title: result.title || "Spreadsheet query result",
      description: result.description || "",
      columns: Enum.map(result.columns, &Map.fetch!(labels, &1)),
      rows: Enum.map(result.rows, &presented_row(&1, result.columns, labels)),
      returned: length(result.rows),
      row_label: if(length(result.rows) == 1, do: "row", else: "rows"),
      offset: result.offset || 0,
      row_count: result.row_count || length(result.rows),
      result_path: result_path(result.id)
    }
  end

  defp presented_table(_result) do
    %{
      title: "Spreadsheet query result",
      description: "",
      columns: [],
      rows: [],
      returned: 0,
      row_label: "rows",
      offset: 0,
      row_count: 0,
      result_path: nil
    }
  end

  defp presented_column_labels(columns, specs) do
    specs_by_name =
      Map.new(specs || [], fn spec ->
        {Map.get(spec, :name) || Map.get(spec, "name"), spec}
      end)

    columns
    |> Enum.map(fn column ->
      spec = Map.get(specs_by_name, column, %{})
      label = Map.get(spec, :label) || Map.get(spec, "label") || column
      {column, label}
    end)
    |> uniquify_labels()
    |> Map.new()
  end

  defp uniquify_labels(column_labels) do
    {labeled, _seen} =
      Enum.map_reduce(column_labels, %{}, fn {column, label}, seen ->
        count = Map.get(seen, label, 0) + 1
        display_label = if count == 1, do: label, else: "#{label} #{count}"
        {{column, display_label}, Map.put(seen, label, count)}
      end)

    labeled
  end

  defp presented_row(row, columns, labels) do
    Map.new(columns, fn column ->
      {Map.fetch!(labels, column), Map.get(row, column)}
    end)
  end

  defp result_path(nil), do: nil
  defp result_path(""), do: nil
  defp result_path(id), do: ~p"/#{id}"

  defp message_groups(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce([], fn {message, index}, groups ->
      put_message_group(message, index, groups)
    end)
    |> Enum.reverse()
  end

  defp put_message_group(
         %{
           role: :tool,
           tool: "present_spreadsheet_query_result",
           result: %PresentedSpreadsheetQueryResult{}
         } =
           message,
         _index,
         groups
       ) do
    [%{kind: :message, message: message} | groups]
  end

  defp put_message_group(%{role: :tool, tool: tool} = message, _index, [
         %{kind: :tools, messages: messages} = group | rest
       ])
       when tool != "write_note" do
    [%{group | messages: messages ++ [message]} | rest]
  end

  defp put_message_group(%{role: :tool, tool: tool} = message, _index, groups)
       when tool != "write_note" do
    [%{kind: :tools, messages: [message]} | groups]
  end

  defp put_message_group(message, index, groups) do
    [%{kind: :message, message: message, message_index: index} | groups]
  end

  defp note_view(input) do
    %{
      title: input |> tool_arg(:title) |> note_text_value(),
      text: input |> tool_arg(:text) |> note_text_value()
    }
  end

  defp note_text_value(value) when is_binary(value), do: String.trim(value)
  defp note_text_value(_value), do: ""

  defp promoted_note_id(%{promoted_note: %{id: id}}) when is_binary(id), do: id
  defp promoted_note_id(%{"promoted_note" => %{"id" => id}}) when is_binary(id), do: id
  defp promoted_note_id(_message), do: nil

  defp tool_blocks(input) do
    input
    |> tool_arg(:blocks)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_refresh_chat_list(socket) do
    if history_enabled?(socket.assigns) do
      assign(socket, :chats, Chats.list())
    else
      socket
    end
  end

  defp maybe_ensure_chat_index_subscription(socket) do
    if history_enabled?(socket.assigns) do
      ensure_chat_index_subscription(socket)
    else
      socket
    end
  end

  defp maybe_ensure_selected_chat(
         %{assigns: %{chat_id: id, selected_chat_id: selected_id}} = socket
       )
       when is_binary(id) and id != "" and id != selected_id do
    cond do
      Chat.exists?(id) ->
        select_chat(socket, id)

      history_enabled?(socket.assigns) ->
        create_existing_conversation(socket, id)

      true ->
        socket
    end
  end

  defp maybe_ensure_selected_chat(socket), do: socket

  defp ensure_chat_index_subscription(%{assigns: %{chats_subscribed?: true}} = socket), do: socket

  defp ensure_chat_index_subscription(socket) do
    socket
    |> assign(:chats, Chats.subscribe(self(), __MODULE__, socket.assigns.id))
    |> assign(:chats_subscribed?, true)
  end

  defp start_blank_chat(socket, mode) do
    socket
    |> unsubscribe_from_previous_chat(nil)
    |> assign(:selected_chat_id, nil)
    |> assign(:subscribed_chat_id, nil)
    |> assign(:chat, empty_chat())
    |> assign(:mode, mode)
    |> assign(:form, chat_form(mode, socket.assigns.model_provider))
  end

  defp ensure_sendable_chat(%{assigns: %{selected_chat_id: id}} = socket, _mode)
       when is_binary(id),
       do: socket

  defp ensure_sendable_chat(socket, mode), do: create_conversation_for_send(socket, mode)

  defp create_conversation_for_send(socket, mode) do
    kind = mode_kind(mode)

    case Chats.create(
           Keyword.put(chat_options(socket, kind), :listed?, history_enabled?(socket.assigns))
         ) do
      %{id: id} ->
        socket
        |> assign(:chats, Chats.list())
        |> select_chat(id)

      {:error, reason} ->
        put_local_error(socket, "Could not start assistant chat: #{inspect(reason)}")
    end
  end

  defp create_existing_conversation(socket, id) do
    case Chats.create(
           chat_options(socket, mode_kind(socket.assigns.mode))
           |> Keyword.put(:id, id)
           |> Keyword.put(:listed?, history_enabled?(socket.assigns))
         ) do
      %{id: ^id} ->
        socket
        |> assign(:chats, Chats.list())
        |> select_chat(id)

      {:error, _reason} ->
        socket
    end
  end

  defp select_chat(socket, id) do
    socket
    |> unsubscribe_from_previous_chat(id)
    |> assign(:selected_chat_id, id)
    |> subscribe_to_chat(id)
  end

  defp subscribe_to_chat(socket, id) do
    snapshot = Chat.subscribe(id, self(), __MODULE__, socket.assigns.id)

    socket
    |> assign(:subscribed_chat_id, id)
    |> assign(:chat, snapshot)
    |> assign(:mode, chat_mode(snapshot))
    |> assign(:model, chat_model(snapshot))
    |> assign(:model_provider, chat_model_provider(snapshot))
    |> assign(:form, chat_form(chat_mode(snapshot), chat_model_provider(snapshot)))
  end

  defp unsubscribe_from_previous_chat(%{assigns: %{subscribed_chat_id: old_id}} = socket, new_id)
       when is_binary(old_id) and old_id != new_id do
    Chat.unsubscribe(old_id, self(), __MODULE__, socket.assigns.id)
    socket
  end

  defp unsubscribe_from_previous_chat(socket, _new_id), do: socket

  defp chat_options(socket, kind) do
    llm_options = assistant_llm_options(socket.assigns.llm_options, socket.assigns.model, kind)

    options = [
      kind: kind,
      model: socket.assigns.model,
      llm_options: llm_options,
      stream?: true
    ]

    case assistant_allow_notes(socket.assigns, kind) do
      {:ok, allow_notes?} -> Keyword.put(options, :allow_notes, allow_notes?)
      :error -> options
    end
  end

  defp assistant_allow_notes(assigns, kind) do
    case Map.fetch(assigns, :allow_notes) do
      {:ok, allow_notes?} -> {:ok, allow_notes?}
      :error -> Map.fetch(assigns, :allow_notes?)
    end
    |> case do
      :error -> {:ok, kind == :research}
      other -> other
    end
  end

  defp history_enabled?(assigns),
    do: not inline?(assigns.variant) and not sidebar?(assigns.variant)

  defp inline?(:inline), do: true
  defp inline?(:compact), do: true
  defp inline?("inline"), do: true
  defp inline?("compact"), do: true
  defp inline?(_variant), do: false

  defp sidebar?(:document_sidebar), do: true
  defp sidebar?("document_sidebar"), do: true
  defp sidebar?(_variant), do: false

  defp assistant_section_class(variant, selected_chat_id) do
    cond do
      sidebar?(variant) ->
        "flex flex-col pt-1"

      inline?(variant) and is_nil(selected_chat_id) ->
        "py-3"

      inline?(variant) ->
        "flex flex-col py-3"

      true ->
        "flex flex-col pt-2"
    end
  end

  defp maybe_navigate_after_send(
         %{assigns: %{variant: :assistant_page, selected_chat_id: id}} = socket
       )
       when is_binary(id) do
    push_navigate(socket, to: ~p"/#{id}")
  end

  defp maybe_navigate_after_send(socket), do: socket

  defp normalize_mode("research"), do: "research"
  defp normalize_mode("edit"), do: "edit"
  defp normalize_mode(_mode), do: "quick"

  defp mode_kind("research"), do: :research
  defp mode_kind("edit"), do: :edit
  defp mode_kind(_mode), do: :chat

  defp normalize_model_provider("gpt"), do: "gpt"
  defp normalize_model_provider(_provider), do: "claude"

  defp put_chat_route(id, model, llm_options) when is_binary(id) do
    with :ok <- Chat.put_model(id, model),
         :ok <- Chat.put_llm_options(id, llm_options) do
      :ok
    end
  end

  defp put_chat_route(_id, _model, _llm_options), do: :ok

  defp assistant_llm_options(base_options, model, kind_or_mode) do
    model
    |> Sheaf.LLM.assistant_llm_options(kind_or_mode)
    |> Keyword.merge(base_options)
  end

  defp selector_label_class(selected_value, value, locked?) do
    [
      "inline-flex items-center gap-1 rounded-sm px-1.5 transition-colors",
      locked? && "cursor-not-allowed",
      not locked? && "cursor-pointer",
      selected_value == value &&
        "text-stone-900 ring-1 ring-inset ring-stone-400/70 dark:text-stone-50 dark:ring-stone-500/80",
      selected_value != value &&
        if(locked?,
          do: "text-stone-400 opacity-60 dark:text-stone-600",
          else:
            "text-stone-500 hover:bg-stone-200/70 hover:text-stone-900 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
        )
    ]
  end

  defp current_chat_title(_chat, nil), do: "New conversation"
  defp current_chat_title(%{title: title}, _id) when is_binary(title), do: title
  defp current_chat_title(_chat, _id), do: "Assistant conversation"

  defp chat_tab_class(selected_chat_id, chat) do
    [
      "inline-flex h-8 max-w-44 shrink-0 items-center gap-1.5 rounded-sm px-2 transition-colors",
      selected_chat_id == chat.id &&
        "bg-stone-900 text-stone-50 dark:bg-stone-100 dark:text-stone-950",
      selected_chat_id != chat.id &&
        "text-stone-500 hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
    ]
  end

  defp chat_kind_icon(chat) do
    case chat_kind(chat) do
      :edit -> "hero-pencil-square"
      :research -> "hero-beaker"
      _kind -> "hero-chat-bubble-left-ellipsis"
    end
  end

  defp chat_listed?(chats, id), do: Enum.any?(chats, &(&1.id == id))

  defp chat_kind(%{kind: :edit}), do: :edit
  defp chat_kind(%{kind: "edit"}), do: :edit
  defp chat_kind(%{kind: :research}), do: :research
  defp chat_kind(%{kind: "research"}), do: :research
  defp chat_kind(_chat), do: :chat

  defp block_preview_id(id), do: "block-preview-#{id}"
  defp block_preview_target(id), do: "##{block_preview_id(id)}"

  defp chat_mode(chat) do
    case chat_kind(chat) do
      :edit -> "edit"
      :research -> "research"
      _kind -> "quick"
    end
  end

  defp chat_model(%{model: model}) when not is_nil(model), do: model
  defp chat_model(_chat), do: Sheaf.LLM.default_model()

  defp chat_model_provider(chat),
    do: chat |> chat_model() |> Sheaf.LLM.assistant_provider_for_model()

  defp input_placeholder(_mode, selected_chat_id) when is_binary(selected_chat_id),
    do: "Reply to assistant"

  defp input_placeholder("edit", _selected_chat_id), do: "Tell the assistant what to edit"
  defp input_placeholder("research", _selected_chat_id), do: "Give the assistant a research task"
  defp input_placeholder(_mode, _selected_chat_id), do: "Ask a quick question"

  defp turn_context(assigns) do
    %{}
    |> maybe_put_open_document(assigns)
    |> maybe_put_selected(assigns)
    |> maybe_put_selected_block_context(assigns)
  end

  defp maybe_put_open_document(context, %{graph: graph, root: root})
       when not is_nil(graph) and not is_nil(root) do
    document = %{
      title: Document.title(graph, root),
      kind: Document.kind(graph, root),
      id: Id.id_from_iri(root)
    }

    context
    |> Map.put(:working_document, document)
    |> Map.put(:open_document, document)
  end

  defp maybe_put_open_document(context, _assigns), do: context

  defp maybe_put_selected(context, %{selected_id: selected_id})
       when is_binary(selected_id) and selected_id != "" do
    Map.put(context, :selected_id, selected_id)
  end

  defp maybe_put_selected(context, _assigns), do: context

  defp maybe_put_selected_block_context(
         context,
         %{graph: graph, root: root, selected_id: selected_id}
       )
       when not is_nil(graph) and not is_nil(root) and is_binary(selected_id) and
              selected_id != "" do
    case CorpusTools.selected_block_context_text(graph, root, selected_id) do
      {:ok, text} -> Map.put(context, :selected_block_context, text)
      {:error, _reason} -> context
    end
  end

  defp maybe_put_selected_block_context(context, _assigns), do: context

  defp put_local_error(socket, text) do
    update(socket, :chat, fn chat ->
      Map.update!(chat, :messages, &(&1 ++ [%{role: :error, text: text}]))
      |> Map.put(:pending, false)
    end)
  end

  defp chat_form(
         mode \\ "quick",
         model_provider \\ Sheaf.LLM.default_assistant_provider(),
         message \\ ""
       ) do
    to_form(%{"message" => message, "mode" => mode, "model_provider" => model_provider},
      as: :chat
    )
  end

  defp current_form_message(%{assigns: %{form: %{params: %{"message" => message}}}})
       when is_binary(message),
       do: message

  defp current_form_message(_socket), do: ""

  defp empty_chat do
    %{
      id: nil,
      title: "Assistant conversation",
      kind: :chat,
      model: Sheaf.LLM.default_model(),
      llm_options: [],
      messages: [],
      pending: false,
      active_tool: nil,
      status_line: nil,
      error: nil
    }
  end
end
