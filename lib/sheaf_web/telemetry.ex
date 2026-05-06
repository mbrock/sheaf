defmodule SheafWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions for Phoenix and VM observations.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller,
       measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view, :connected],
        keep: &sheaf_live_view_metadata?/1,
        tag_values: &live_view_tag_values/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_params.stop.duration",
        tags: [:view, :connected],
        keep: &sheaf_live_view_metadata?/1,
        tag_values: &live_view_tag_values/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event, :connected],
        keep: &sheaf_live_view_metadata?/1,
        tag_values: &live_view_tag_values/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.render.stop.duration",
        tags: [:view, :connected, :changed, :force],
        keep: &sheaf_live_view_metadata?/1,
        tag_values: &live_view_tag_values/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_component.update.stop.duration",
        tags: [:view, :component, :connected],
        keep: &sheaf_live_component_metadata?/1,
        tag_values: &live_component_tag_values/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_component.handle_event.stop.duration",
        tags: [:view, :component, :event, :connected],
        keep: &sheaf_live_component_metadata?/1,
        tag_values: &live_component_tag_values/1,
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {SheafWeb, :count_users, []}
    ]
  end

  defp sheaf_live_view_metadata?(metadata) do
    metadata
    |> Map.get(:socket)
    |> socket_view()
    |> sheaf_module?()
  end

  defp sheaf_live_component_metadata?(metadata) do
    socket_view = metadata |> Map.get(:socket) |> socket_view()
    component = metadata |> Map.get(:component) |> module_tag()

    sheaf_module?(socket_view) and sheaf_module?(component)
  end

  defp live_view_tag_values(metadata) do
    socket = Map.get(metadata, :socket)

    metadata
    |> Map.put(:view, socket_view(socket))
    |> Map.put(:connected, socket_connected?(socket))
    |> Map.put(:changed, Map.get(metadata, :changed?, false))
    |> Map.put(:force, Map.get(metadata, :force?, false))
  end

  defp live_component_tag_values(metadata) do
    socket = Map.get(metadata, :socket)

    metadata
    |> Map.put(:view, socket_view(socket))
    |> Map.put(:component, metadata |> Map.get(:component) |> module_tag())
    |> Map.put(:connected, socket_connected?(socket))
  end

  defp socket_view(%Phoenix.LiveView.Socket{view: view}), do: module_tag(view)
  defp socket_view(_socket), do: :unknown

  defp socket_connected?(%Phoenix.LiveView.Socket{} = socket),
    do: Phoenix.LiveView.connected?(socket)

  defp socket_connected?(_socket), do: false

  defp module_tag(module) when is_atom(module), do: module
  defp module_tag(_module), do: :unknown

  defp sheaf_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?([
      "Elixir.Sheaf",
      "Elixir.SheafWeb"
    ])
  end

  defp sheaf_module?(_module), do: false
end
