defmodule Sheaf.Expert do
  @moduledoc """
  Bridge to an Expert engine node for Sheaf code intelligence.

  This deliberately keeps the Expert engine in a separate BEAM VM. Sheaf owns
  the parent process and calls the engine directly over distributed Erlang,
  bypassing the LSP JSON-RPC layer.
  """

  use GenServer

  require Logger

  @default_timeout :timer.minutes(2)

  defstruct [
    :engine_node,
    :port,
    :project,
    :status
  ]

  @type status :: :starting | :ready | :stopped

  @doc """
  Starts the bridge for a project root.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the bridge status and engine node name.
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Rebuilds the Expert workspace index.
  """
  def reindex(server \\ __MODULE__, timeout \\ @default_timeout) do
    GenServer.call(server, :reindex, timeout)
  end

  @doc """
  Queries Expert workspace symbols.
  """
  def workspace_symbols(
        query,
        server \\ __MODULE__,
        timeout \\ @default_timeout
      )
      when is_binary(query) do
    GenServer.call(server, {:workspace_symbols, query}, timeout)
  end

  @doc """
  Returns documentation, specs, callbacks, and types for a compiled module.
  """
  def docs(module, opts \\ []) when is_atom(module) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    engine_opts = Keyword.take(opts, [:exclude_hidden])

    GenServer.call(server, {:docs, module, engine_opts}, timeout)
  end

  @doc """
  Returns the structural outline for an Elixir source file.
  """
  def outline(path, opts \\ []) when is_binary(path) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    GenServer.call(server, {:outline, path}, timeout)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    attach_local_group_leader()
    :ok = ensure_expert_loaded()

    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    state = %__MODULE__{
      project: build_project(root),
      status: :starting
    }

    {:ok, state, {:continue, :start_engine}}
  end

  @impl GenServer
  def handle_continue(:start_engine, %__MODULE__{} = state) do
    case start_engine(state.project) do
      {:ok, engine_node, port} ->
        Logger.info("Expert engine node started: #{inspect(engine_node)}")

        {:noreply,
         %{state | engine_node: engine_node, port: port, status: :ready}}

      {:error, reason} ->
        Logger.error(
          "Expert engine bridge failed to start: #{inspect(reason)}"
        )

        {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, %{status: state.status, engine_node: state.engine_node}, state}
  end

  def handle_call(:reindex, _from, %__MODULE__{status: :ready} = state) do
    reply = reindex_workspace(state)
    {:reply, reply, state}
  end

  def handle_call(
        {:workspace_symbols, query},
        _from,
        %__MODULE__{status: :ready} = state
      ) do
    reply =
      with :ok <- ensure_index_loaded(state) do
        state
        |> erpc(Engine.CodeIntelligence.Symbols, :for_workspace, [query])
        |> normalize_symbols()
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:docs, module, opts},
        _from,
        %__MODULE__{status: :ready} = state
      ) do
    reply =
      erpc(state, Engine.CodeIntelligence.Docs, :for_module, [module, opts])

    {:reply, reply, state}
  end

  def handle_call(
        {:outline, path},
        _from,
        %__MODULE__{status: :ready} = state
      ) do
    reply =
      with {:ok, document} <- document_from_path(state.project, path),
           symbols when is_list(symbols) <-
             erpc(state, Engine.CodeIntelligence.Symbols, :for_document, [
               document
             ]) do
        {:ok, symbols}
      else
        {:error, _reason} = error -> error
        other -> {:error, {:unexpected_outline_result, other}}
      end

    {:reply, reply, state}
  end

  def handle_call(_request, _from, %__MODULE__{} = state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    Logger.debug("Expert engine output: #{inspect(data)}")
    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, status}},
        %__MODULE__{port: port} = state
      ) do
    Logger.warning("Expert engine port exited with status #{status}")
    {:noreply, %{state | status: :stopped}}
  end

  def handle_info({:EXIT, port, reason}, %__MODULE__{port: port} = state) do
    Logger.warning("Expert engine port exited: #{inspect(reason)}")
    {:noreply, %{state | status: :stopped}}
  end

  def handle_info({:EXIT, _pid, :normal}, %__MODULE__{} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:nodedown, node, _info},
        %__MODULE__{engine_node: node} = state
      ) do
    Logger.warning("Expert engine node went down: #{inspect(node)}")
    {:noreply, %{state | status: :stopped}}
  end

  def handle_info(_message, %__MODULE__{} = state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{engine_node: node}) when is_atom(node) do
    _ = :erpc.call(node, System, :stop, [], 1_000)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp attach_local_group_leader do
    case Process.whereis(:user) do
      pid when is_pid(pid) -> Process.group_leader(self(), pid)
      _other -> :ok
    end
  end

  defp build_project(root) do
    uri = call(Forge.Document.Path, :to_uri, [root])
    call(Forge.Project, :new, [uri])
  end

  defp call(module, function), do: call(module, function, [])
  defp call(module, function, args), do: apply(module, function, args)

  defp document_from_path(project, path) do
    path = absolute_project_path(project, path)

    with {:ok, text} <- File.read(path) do
      uri = call(Forge.Document.Path, :to_uri, [path])
      {:ok, call(Forge.Document, :new, [uri, text, 0, language_id(path)])}
    end
  end

  defp absolute_project_path(_project, "file://" <> _rest = uri) do
    call(Forge.Document.Path, :from_uri, [uri])
  end

  defp absolute_project_path(_project, "/" <> _rest = path), do: path

  defp absolute_project_path(project, path) do
    project
    |> project_root_path()
    |> Path.join(path)
    |> Path.expand()
  end

  defp project_root_path(project) do
    call(Forge.Project, :root_path, [project])
  end

  defp language_id(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "phoenix-heex"
      _other -> nil
    end
  end

  defp start_engine(project) do
    with :ok <- call(Forge.Project, :ensure_workspace, [project]),
         {:ok, {namespaced_paths, mix_home}} <-
           call(Expert.EngineNode.Builder, :build_engine, [project]),
         {:ok, engine_paths} <- engine_paths(namespaced_paths),
         {:ok, port} <- open_engine_port(project, engine_paths, mix_home),
         engine_node = call(Forge.Project, :node_name, [project]),
         :ok <- wait_for_node(engine_node, port),
         :ok <- bootstrap_engine(project),
         :ok <-
           erpc(engine_node, Engine, :ensure_apps_started, [
             call(Expert.Progress, :noop_token)
           ]) do
      {:ok, engine_node, port}
    end
  end

  defp engine_paths(namespaced_paths) do
    with first when is_binary(first) <- List.first(namespaced_paths),
         {:ok, dev_build_path} <- dev_build_path(first) do
      paths =
        dev_build_path
        |> Path.join("lib/**/ebin")
        |> Path.wildcard()

      {:ok, paths}
    else
      _ -> {:error, {:invalid_engine_paths, namespaced_paths}}
    end
  end

  defp dev_build_path(namespaced_ebin_path) do
    case namespaced_ebin_path |> Path.split() |> Enum.reverse() do
      ["ebin", _app, "lib", "dev_ns", "_build" | rest] ->
        root = rest |> Enum.reverse() |> Path.join()
        {:ok, Path.join([root, "_build", "dev"])}

      _ ->
        {:error, {:invalid_namespaced_ebin_path, namespaced_ebin_path}}
    end
  end

  defp open_engine_port(project, engine_paths, mix_home) do
    path_args =
      (engine_paths ++ project_ebin_paths(project))
      |> Enum.uniq()
      |> Enum.flat_map(&["-pa", Path.expand(&1)])

    engine_node = call(Forge.Project, :node_name, [project])

    child_code =
      quote do
        node = unquote(engine_node)

        case Node.start(node, :longnames) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, reason} ->
            raise "could not start Expert engine node: #{inspect(reason)}"
        end

        IO.puts("ok")
      end
      |> Macro.to_string()
      |> Base.encode64()

    env = if is_binary(mix_home), do: [{"MIX_HOME", mix_home}], else: []

    args =
      path_args ++
        [
          "--cookie",
          Node.get_cookie(),
          "--no-halt",
          "-e",
          "System.argv() |> hd() |> Base.decode64!() |> Code.eval_string()",
          child_code
        ]

    port =
      call(Expert.Port, :open_elixir, [
        project,
        [args: args, env: env, line: 4096]
      ])

    {:ok, port}
  end

  defp wait_for_node(engine_node, port) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_wait_for_node(engine_node, port, deadline)
  end

  defp do_wait_for_node(engine_node, port, deadline) do
    _ = Node.connect(engine_node)

    receive do
      {:nodeup, ^engine_node, _} ->
        :ok

      {^port, {:data, data}} ->
        Logger.debug("Expert engine startup output: #{inspect(data)}")
        do_wait_for_node(engine_node, port, deadline)

      {^port, {:exit_status, status}} ->
        {:error, {:engine_node_exit, status}}
    after
      250 ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, {:engine_node_start_timeout, engine_node}}
        else
          do_wait_for_node(engine_node, port, deadline)
        end
    end
  end

  defp bootstrap_engine(project) do
    args = [
      project,
      call(Forge.Document.Store, :entropy),
      app_configs(),
      Node.self(),
      :logger.get_primary_config().metadata
    ]

    erpc(
      call(Forge.Project, :node_name, [project]),
      Engine.Bootstrap,
      :init,
      args
    )
  end

  defp app_configs do
    for {app, _, _} <- Application.loaded_applications() do
      {app, Application.get_all_env(app)}
    end
  end

  defp ensure_index_loaded(%__MODULE__{} = state) do
    case erpc(state, Engine.Search.Store, :loaded?, []) do
      true -> :ok
      false -> reindex_workspace(state)
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_search_store_loaded, other}}
    end
  end

  defp reindex_workspace(%__MODULE__{} = state) do
    with :ok <- erpc(state, Engine.Search.Store, :enable, []),
         :ok <-
           erpc(state, Engine.Commands.Reindex, :perform, [state.project]),
         :ok <- await_reindex(state) do
      :ok
    end
  end

  defp await_reindex(%__MODULE__{} = state) do
    deadline = System.monotonic_time(:millisecond) + @default_timeout
    do_await_reindex(state, deadline)
  end

  defp do_await_reindex(%__MODULE__{} = state, deadline) do
    running? = erpc(state, Engine.Commands.Reindex, :running?, [])
    loaded? = erpc(state, Engine.Search.Store, :loaded?, [])

    cond do
      loaded? == true and running? == false ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :reindex_timeout}

      true ->
        Process.sleep(500)
        do_await_reindex(state, deadline)
    end
  end

  defp normalize_symbols(symbols) when is_list(symbols), do: {:ok, symbols}
  defp normalize_symbols({:error, _} = error), do: error

  defp normalize_symbols(other),
    do: {:error, {:unexpected_symbols_result, other}}

  defp erpc(%__MODULE__{engine_node: node}, module, function, args),
    do: erpc(node, module, function, args)

  defp erpc(node, module, function, args) do
    :erpc.call(node, module, function, args, @default_timeout)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ensure_expert_loaded do
    case Code.ensure_loaded(Expert.EngineNode.Builder) do
      {:module, Expert.EngineNode.Builder} ->
        :ok

      {:error, _} ->
        System.put_env(
          "EXPERT_ENGINE_PATH",
          System.get_env(
            "EXPERT_ENGINE_PATH",
            "/home/mbrock/src/expert/apps/engine"
          )
        )

        with {:ok, ebin_paths} <- expert_ebin_paths() do
          Enum.each(ebin_paths, &Code.prepend_path(String.to_charlist(&1)))
          :ok
        end
    end
  end

  defp expert_ebin_paths do
    candidates =
      System.get_env("EXPERT_EBIN_ROOTS", "")
      |> String.split(":", trim: true)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "lib/*/ebin")))

    candidates =
      candidates ++
        expert_install_ebins() ++
        expert_source_ebins()

    ebin_paths = Enum.uniq(candidates)

    if Enum.any?(ebin_paths, &(Path.basename(Path.dirname(&1)) == "expert")) do
      {:ok, ebin_paths}
    else
      {:error, :expert_ebins_not_found}
    end
  end

  defp expert_install_ebins do
    "/home/mbrock/.cache/mix/installs/*/*/_build/dev/lib/*/ebin"
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      path =~ "/lib/expert/ebin" or
        File.exists?(
          Path.join([Path.dirname(Path.dirname(path)), "expert", "ebin"])
        )
    end)
    |> case do
      [] ->
        []

      paths ->
        paths
        |> Enum.map(&install_build_root/1)
        |> Enum.uniq()
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    end
  end

  defp install_build_root(ebin_path) do
    ebin_path
    |> Path.split()
    |> Enum.reverse()
    |> then(fn ["ebin", _app, "lib" | rest] -> rest end)
    |> Enum.reverse()
    |> Path.join()
  end

  defp expert_source_ebins do
    expert_source =
      System.get_env("EXPERT_SOURCE", "/home/mbrock/src/expert/apps/expert")

    expert_source
    |> Path.join("_build/dev/lib/*/ebin")
    |> Path.wildcard()
  end

  defp project_ebin_paths(project) do
    project
    |> project_root_path()
    |> Path.join("_build/dev/lib/*/ebin")
    |> Path.wildcard()
  end
end
