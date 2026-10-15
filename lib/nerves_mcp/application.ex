defmodule NervesMCP.Application do
  @moduledoc false

  use Application

  alias EMCP.SessionStore.ETS

  @impl true
  def start(_type, _args) do
    ETS.init()

    children =
      case NervesMCP.Devices.configured() do
        # Nothing configured yet. The escript starts the app before its args are
        # parsed, so `NervesMCP.CLI.run/1` starts the children.
        [] ->
          []

        # Configured, either by config.exs or by `mix nerves_mcp` parsing its
        # args before app.start. Start everything.
        devices ->
          devices
          |> NervesMCP.Devices.validate!()
          |> children(Application.get_env(:nerves_mcp, :port, 13000))
      end

    # The registry outlives the other children, which `NervesMCP.CLI` replaces. It comes first
    # and the strategy is rest_for_one, so whatever registers in it restarts after it does.
    opts = [strategy: :rest_for_one, name: NervesMCP.Supervisor]
    Supervisor.start_link([{Registry, keys: :unique, name: NervesMCP.Registry} | children], opts)
  end

  # How long a stop waits for open connections, down from ThousandIsland's
  # 15_000. A client's GET /mcp event stream never ends on its own, so a stop
  # with one open always took the full 15 s, and the client reconnects anyway.
  # A request still running when the server stops gets this long to finish.
  @shutdown_timeout 1_000

  @doc """
  A `NervesMCP.Device` per device, then the HTTP listener, so no request arrives
  before the devices it names exist.
  """
  @spec children([NervesMCP.Devices.device()], pos_integer()) :: [Supervisor.module_spec()]
  def children(devices, port) do
    [
      {NervesMCP.Devices, devices},
      {Bandit,
       plug: NervesMCP.Router,
       port: port,
       ip: :loopback,
       thousand_island_options: [shutdown_timeout: @shutdown_timeout]}
    ]
  end
end
