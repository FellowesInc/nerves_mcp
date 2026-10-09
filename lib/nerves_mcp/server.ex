defmodule NervesMCP.Server do
  @moduledoc """
  MCP Server for interacting with Nerves devices.

  A tool that needs a device it cannot reach returns an error (see
  `NervesMCP.Tools.Device`) rather than disappearing from the list, because
  `notifications/tools/list_changed` only reaches clients holding an open SSE
  stream and a client that misses it never gets the tool back. So `:down` and
  `:unknown` list everything.

  `:shell` is the one mode that lists differently, because it is the one mode
  where a tool cannot do its advertised work rather than merely being blocked:
  a serial that does not run Elixir has no `device_eval` and no RingLogger. It
  swaps in the raw shell eval tools and drops `grep_ring_logger`. `grep_dmesg`
  stays, since it only needs `dmesg` and runs it through the shell instead.

  The list is for every configured device at once, and the two lists share tool
  names, so it is the shell list only when every device is in `:shell`. A shell
  device among Elixir ones gets the Elixir tools, which fail on it, and
  `device_status` says why.
  """

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices
  alias NervesMCP.Tools

  @base [
    Tools.ListDevices,
    Tools.IsDeviceUp,
    Tools.IsDeviceUpdatedTo,
    Tools.DeviceStatus,
    Tools.DeviceOutput,
    Tools.GrepDmesg,
    Tools.SetDeviceAddress
  ]

  @instructions """
  Tools for interacting with connected Nerves devices over serial or SSH.

  Every device tool takes a `device` name. It can be left out when only one
  device is configured, and `list_devices` lists the names.

  `device_eval`/`device_eval_output` evaluate Elixir on the device,
  `grep_ring_logger` and `grep_dmesg` filter its logs. All of them need a live
  device: while the device is down they return a "Device is down" error, so use
  `is_device_up` / `is_device_updated_to` to wait for it to come back after a
  reboot or firmware update, then retry.

  Over SSH, when the device's name has stopped resolving and there is no usable
  address for it, that error says so. Ask the user for the device's IP address
  and pass it to `set_device_address`.

  `device_output` reads what the device printed into the session, which is the
  only way to see output from a process spawned by an earlier `device_eval`.

  When every device is a serial that responds but does not run Elixir,
  `device_eval` and `device_eval_output` take a raw shell command instead,
  `grep_dmesg` shells out to `dmesg`, and `grep_ring_logger` is not listed at
  all. With several devices where some do run Elixir, the Elixir tools are
  listed, and they don't work on a shell device. `device_status` reports each
  device's mode and which tools apply to it.
  """

  @spec server() :: struct()
  def server() do
    devices = Devices.names()
    Enum.each(devices, &DeviceProbe.touch/1)

    EMCP.Server.new(
      name: "nerves-mcp",
      version: "0.1.0",
      instructions: @instructions <> configured(devices),
      tools: devices |> Enum.map(&DeviceProbe.mode/1) |> tools_for_all()
    )
  end

  defp configured([]), do: ""
  defp configured(devices), do: "\nConfigured devices: #{Enum.join(devices, ", ")}.\n"

  @doc "The tools listed for every configured device's probed mode."
  @spec tools_for_all([DeviceProbe.mode()]) :: [module()]
  def tools_for_all([_ | _] = modes) do
    if Enum.all?(modes, &(&1 == :shell)), do: tools_for(:shell), else: tools_for(:nerves)
  end

  def tools_for_all([]), do: tools_for(:unknown)

  @doc "The tools listed for a probed mode."
  @spec tools_for(DeviceProbe.mode()) :: [module()]
  def tools_for(:shell), do: @base ++ [Tools.ShellEval, Tools.ShellEvalOutput]

  def tools_for(_mode),
    do: @base ++ [Tools.DeviceEval, Tools.DeviceEvalOutput, Tools.GrepRingLogger]
end
