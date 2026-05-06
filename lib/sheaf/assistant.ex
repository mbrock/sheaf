defmodule Sheaf.Assistant do
  @moduledoc """
  A small GenServer-backed assistant loop around ReqLLM.

  The assistant owns a `ReqLLM.Context`, starts LLM calls in supervised tasks,
  executes requested tools, appends tool results, and repeats until the model
  returns a final answer or the configured tool-round limit is reached.
  """

  use GenServer

  require OpenTelemetry.Tracer, as: Tracer

  alias ReqLLM.{Context, Response, StreamResponse}

  @default_max_tool_rounds 8
  @default_timeout 300_000
  @default_task_supervisor Sheaf.Assistant.TaskSupervisor

  defstruct [
    :model,
    :context,
    :pending_from,
    :task_ref,
    :task_context,
    :task_round,
    :task_opts,
    :task_supervisor,
    :generate_text,
    :stream_text,
    tools: [],
    llm_options: [],
    max_tool_rounds: @default_max_tool_rounds
  ]

  @type t :: %__MODULE__{}

  @doc """
  Starts an assistant process.

  Options:

    * `:model` - ReqLLM model spec, defaulting to `Sheaf.LLM.default_model/0`.
    * `:context` - initial `ReqLLM.Context`, defaulting to an empty context.
    * `:tools` - list of `ReqLLM.Tool` structs available to the loop.
    * `:llm_options` - default options passed to `ReqLLM.generate_text/3`.
    * `:max_tool_rounds` - maximum tool-call turns before returning an error.
    * `:task_supervisor` - task supervisor name or pid.
    * `:generate_text` - test seam, defaulting to `ReqLLM.generate_text/3`.
    * `:stream_text` - test seam, defaulting to `ReqLLM.stream_text/3`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Runs one user turn through the assistant loop.
  """
  @spec run(GenServer.server(), String.t() | ReqLLM.Message.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def run(server, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    GenServer.call(
      server,
      {:run, input, Keyword.delete(opts, :timeout)},
      timeout
    )
  end

  @doc """
  Returns the current conversation context.
  """
  @spec context(GenServer.server()) :: Context.t()
  def context(server), do: GenServer.call(server, :context)

  @doc """
  Replaces the current conversation context.
  """
  @spec put_context(GenServer.server(), Context.t()) :: :ok
  def put_context(server, %Context{} = context) do
    GenServer.call(server, {:put_context, context})
  end

  @doc """
  Replaces the model used for subsequent assistant turns.
  """
  @spec put_model(GenServer.server(), term()) :: :ok | {:error, :busy}
  def put_model(server, model) do
    GenServer.call(server, {:put_model, model})
  end

  @doc """
  Replaces the default LLM options used for subsequent assistant turns.
  """
  @spec put_llm_options(GenServer.server(), keyword()) ::
          :ok | {:error, :busy}
  def put_llm_options(server, opts) when is_list(opts) do
    GenServer.call(server, {:put_llm_options, opts})
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       model: Keyword.get(opts, :model, Sheaf.LLM.default_model()),
       context: Keyword.get(opts, :context, Context.new()),
       tools: Keyword.get(opts, :tools, []),
       llm_options: Keyword.get(opts, :llm_options, []),
       max_tool_rounds:
         Keyword.get(opts, :max_tool_rounds, @default_max_tool_rounds),
       task_supervisor:
         Keyword.get(opts, :task_supervisor, @default_task_supervisor),
       generate_text:
         Keyword.get(opts, :generate_text, &ReqLLM.generate_text/3),
       stream_text: Keyword.get(opts, :stream_text, &ReqLLM.stream_text/3)
     }}
  end

  @impl true
  def handle_call({:run, _input, _opts}, _from, %{task_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, input, opts}, from, state) do
    context = append_user_input(state.context, input)
    state = start_inference(%{state | pending_from: from}, context, 0, opts)
    {:noreply, state}
  end

  def handle_call(:context, _from, state), do: {:reply, state.context, state}

  def handle_call({:put_context, context}, _from, %{task_ref: nil} = state) do
    {:reply, :ok, %{state | context: context}}
  end

  def handle_call({:put_context, _context}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:put_model, model}, _from, %{task_ref: nil} = state) do
    {:reply, :ok, %{state | model: model}}
  end

  def handle_call({:put_model, _model}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:put_llm_options, opts}, _from, %{task_ref: nil} = state) do
    {:reply, :ok, %{state | llm_options: opts}}
  end

  def handle_call({:put_llm_options, _opts}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    handle_inference_result(result, %{state | task_ref: nil})
  end

  def handle_info({ref, _result}, state) when is_reference(ref),
    do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref, pending_from: from} = state
      ) do
    GenServer.reply(from, {:error, {:task_down, reason}})
    {:noreply, clear_task(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:noreply, state}

  defp start_inference(state, %Context{} = context, round, opts) do
    llm_options =
      state.llm_options
      |> Keyword.merge(opts)
      |> Keyword.put(:model, state.model)
      |> Keyword.put(:tools, state.tools)
      |> Sheaf.LLM.text_request_options()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Tracer.with_span "Sheaf.Assistant.inference", %{
          kind: :internal,
          attributes: [
            {"sheaf.assistant.model", inspect(state.model)},
            {"sheaf.assistant.tool_count", length(state.tools)},
            {"sheaf.assistant.tool_round", round},
            {"sheaf.assistant.stream", stream?(opts)}
          ]
        } do
          generate_response(state, context, llm_options, opts)
        end
      end)

    %{
      state
      | task_ref: task.ref,
        task_context: context,
        task_round: round,
        task_opts: opts
    }
  end

  defp generate_response(state, %Context{} = context, llm_options, opts) do
    if stream?(opts) do
      case state.stream_text.(state.model, context, llm_options) do
        {:ok, %StreamResponse{} = stream_response} ->
          StreamResponse.process_stream(
            stream_response,
            stream_callbacks(opts)
          )

        other ->
          other
      end
    else
      state.generate_text.(state.model, context, llm_options)
    end
  end

  defp stream?(opts), do: Keyword.get(opts, :stream, false) == true

  defp stream_callbacks(opts) do
    [
      on_chunk: Keyword.get(opts, :on_stream_chunk),
      on_result:
        Keyword.get(opts, :on_text_delta) || Keyword.get(opts, :on_result),
      on_thinking:
        Keyword.get(opts, :on_thinking_delta) ||
          Keyword.get(opts, :on_thinking),
      on_tool_call:
        Keyword.get(opts, :on_tool_call_delta) ||
          Keyword.get(opts, :on_tool_call)
    ]
    |> Enum.reject(fn {_key, callback} -> is_nil(callback) end)
  end

  defp handle_inference_result({:ok, %Response{} = response}, state) do
    classification = Response.classify(response)
    tool_calls = Response.tool_calls(response)

    context =
      Context.merge_response(state.task_context, response, tools: state.tools).context

    if classification.type == :tool_calls and tool_calls != [] do
      continue_tool_loop(response, context, tool_calls, state)
    else
      finish_run({:ok, response}, %{state | context: context})
    end
  end

  defp handle_inference_result({:error, reason}, state) do
    finish_run({:error, reason}, state)
  end

  defp handle_inference_result(other, state) do
    finish_run({:error, {:invalid_task_result, other}}, state)
  end

  defp continue_tool_loop(response, context, tool_calls, state) do
    if state.task_round >= state.max_tool_rounds do
      finish_run({:error, {:max_tool_rounds, response}}, %{
        state
        | context: context
      })
    else
      case execute_tools(context, tool_calls, state.tools) do
        {:ok, context} ->
          state =
            start_inference(
              %{state | context: context},
              context,
              state.task_round + 1,
              state.task_opts || []
            )

          {:noreply, state}

        {:error, reason} ->
          finish_run({:error, {:tool_execution_failed, reason}}, %{
            state
            | context: context
          })
      end
    end
  end

  defp execute_tools(context, tool_calls, tools) do
    {:ok, Context.execute_and_append_tools(context, tool_calls, tools)}
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp finish_run(result, %{pending_from: from} = state) do
    GenServer.reply(from, result)
    {:noreply, clear_task(state)}
  end

  defp clear_task(state) do
    %{
      state
      | pending_from: nil,
        task_ref: nil,
        task_context: nil,
        task_round: nil,
        task_opts: nil
    }
  end

  defp append_user_input(context, %ReqLLM.Message{role: :user} = message) do
    Context.append(context, message)
  end

  defp append_user_input(context, input) when is_binary(input) do
    Context.append(context, Context.user(input))
  end
end
