defmodule Mix.Tasks.NervesMcp do
  @shortdoc "Start NervesMCP server connected to a device"

  @moduledoc """
  Starts the NervesMCP server connected to a Nerves device.

  ## Examples

      mix nerves_mcp /dev/ttyUSB0
      mix nerves_mcp nerves.local --user root
      mix nerves_mcp --serial /dev/ttyACM0 --speed 9600
      mix nerves_mcp --ssh 192.168.1.100 --port 4000
      mix nerves_mcp nerves.local --no-repl

  `--no-repl` skips the stdin console and blocks instead, so the task survives
  stdin EOF and can run in the background. Ctrl-C still stops it.

  See `NervesMCP.CLI` for all options.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # `app.config` loads config/config.exs without starting anything, so the CLI
    # args land in the application env before `NervesMCP.Application` reads them.
    # Starting first would bring up Bandit and the connection on the config port
    # and host, and the CLI overrides would be ignored.
    Mix.Task.run("app.config")

    config = NervesMCP.CLI.configure(args)

    Mix.Task.run("app.start")

    NervesMCP.CLI.announce(config)
    NervesMCP.CLI.serve(config)
  end
end
