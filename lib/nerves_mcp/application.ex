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
        # Connection configured via config.exs — start everything
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
        # No config — CLI.run/1 will start children later
        []
      end

    opts = [strategy: :one_for_one, name: NervesMCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
