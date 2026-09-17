defmodule NervesMCP.Server do
  @moduledoc """
  MCP Server for interacting with Nerves devices.

  The tool names are the same in every mode. A tool that needs a device it
  cannot reach returns an error (see `NervesMCP.Tools.Device`) rather than
  disappearing from the list, because `notifications/tools/list_changed` only
  reaches clients holding an open SSE stream and a client that misses it never
  gets the tool back.

  The one thing the probed mode still decides is which implementation answers
  to `device_eval`/`device_eval_output`: `:shell` swaps in the raw shell
  versions for a serial that responds but does not run Elixir.
  """

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Tools

  @base [Tools.IsDeviceUp, Tools.IsDeviceUpdatedTo, Tools.DeviceStatus]
  @device [Tools.GrepRingLogger, Tools.GrepDmesg]

  @instructions """
  Tools for interacting with a connected Nerves device over serial or SSH.

  `device_eval`/`device_eval_output` evaluate Elixir on the device,
  `grep_ring_logger` and `grep_dmesg` filter its logs. All of them need a live
  device: while the device is down they return a "Device is down" error, so use
  `is_device_up` / `is_device_updated_to` to wait for it to come back after a
  reboot or firmware update, then retry.

  On a serial that responds but does not run Elixir, `device_eval` and
  `device_eval_output` take a raw shell command instead. `device_status` reports
  which of the two is in force.
  """

  @spec server() :: struct()
  def server() do
    DeviceProbe.touch()

    EMCP.Server.new(
      name: "nerves-mcp",
      version: "0.1.0",
      instructions: @instructions,
      tools: tools_for(DeviceProbe.mode())
    )
  end

  @doc "The tools listed for a probed mode."
  @spec tools_for(DeviceProbe.mode()) :: [module()]
  def tools_for(:shell), do: @base ++ [Tools.ShellEval, Tools.ShellEvalOutput | @device]
  def tools_for(_mode), do: @base ++ [Tools.DeviceEval, Tools.DeviceEvalOutput | @device]
end
