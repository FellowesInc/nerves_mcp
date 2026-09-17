defmodule Mix.Tasks.NervesMcp do
  @shortdoc "Start NervesMCP server connected to a device"

  @moduledoc """
  Starts the NervesMCP server connected to a Nerves device.

  ## Examples

      mix nerves_mcp /dev/ttyUSB0
      mix nerves_mcp nerves.local --user root
      mix nerves_mcp --serial /dev/ttyACM0 --speed 9600
      mix nerves_mcp --ssh 192.168.1.100 --port 4000
      mix nerves_mcp nerves.local --fallback-host 192.168.1.252
      mix nerves_mcp nerves.local --no-repl

  `--no-repl` skips the stdin console and blocks instead, so the task survives
  stdin EOF and can run in the background. Ctrl-C still stops it.

  See `NervesMCP.CLI` for all options.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> NervesMCP.CLI.run()
    |> NervesMCP.CLI.serve()
  end
end
