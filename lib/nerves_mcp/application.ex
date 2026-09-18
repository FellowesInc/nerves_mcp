defmodule NervesMCP.Application do
  @moduledoc false

  use Application

  alias EMCP.SessionStore.ETS

  @impl true
  def start(_type, _args) do
    ETS.init()

    config = Application.get_env(:nerves_mcp, :connection, [])

    children =
      if Keyword.has_key?(config, :type) do
        # Configured, either by config.exs or by `mix nerves_mcp` parsing its
        # args before app.start. Start everything.
        connection_child =
          case Keyword.fetch!(config, :type) do
            :uart -> NervesMCP.Connection.UART
            :ssh -> NervesMCP.Connection.SSH
          end

        port = Application.get_env(:nerves_mcp, :port, 13000)

        [
          NervesMCP.History,
          {Bandit, plug: NervesMCP.Router, port: port, ip: :loopback},
          connection_child,
          NervesMCP.DeviceProbe
        ]
      else
        # Nothing configured yet. The escript starts the app before its args are
        # parsed, so `NervesMCP.CLI.run/1` starts the children.
        []
      end

    opts = [strategy: :one_for_one, name: NervesMCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
