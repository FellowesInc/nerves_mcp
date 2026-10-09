defmodule NervesMCP.Tools.DeviceStatus do
  @moduledoc """
  Report what the device probe currently detects on the other end of the
  connection, and therefore which tools are being offered.

  Always available. Pass `refresh: true` to run a fresh probe now instead of
  reading the last cached result.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices
  alias NervesMCP.Server
  alias NervesMCP.Tools
  alias NervesMCP.Tools.Device

  @impl EMCP.Tool
  def name(), do: "device_status"

  @impl EMCP.Tool
  def description(),
    do:
      "Report the detected device state (nerves/elixir/shell/down) that decides which tools are offered"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        device: Device.schema(),
        refresh: %{
          type: :boolean,
          description:
            "Probe the device now instead of using the last cached result (default: false)"
        }
      },
      required: []
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    Device.with_device(args, &status(&1, args["refresh"]))
  end

  defp status(device, refresh?) do
    if refresh?, do: DeviceProbe.refresh(device)

    status = DeviceProbe.status(device)
    listed = Devices.names() |> Enum.map(&DeviceProbe.mode/1) |> Server.tools_for_all()

    text = """
    Device: #{device}
    Detected mode: #{status.mode}
    Detail: #{status.detail}
    Offered tools: #{offered(status.mode, listed)}
    Idle: #{format_ms(status.idle_ms)}
    Last probe: #{last_probe(status.last_probe_ms_ago)}
    """

    text = text <> connection(Device.connection_status(device))

    EMCP.Tool.response([%{"type" => "text", "text" => String.trim_trailing(text)}])
  end

  defp connection(nil), do: ""

  defp connection(status) do
    "SSH target: #{status.target}\n" <>
      line("Known address", status.address) <> line("Reason", status.reason)
  end

  defp line(_label, nil), do: ""
  defp line(label, value), do: "#{label}: #{value}\n"

  @doc """
  The tools the server lists, `listed`, as they apply to a device in `mode`.

  The list covers every device, so a shell device among Elixir ones sees the Elixir tools.
  """
  @spec offered(DeviceProbe.mode(), [module()]) :: String.t()
  def offered(mode, listed) do
    names = Enum.map_join(listed, ", ", & &1.name())

    cond do
      mode == :shell and Tools.ShellEval in listed ->
        names <> " (device_eval takes a shell command in this mode)"

      mode == :shell ->
        names <>
          " (this device doesn't run Elixir, but another device does, so device_eval, " <>
          "device_eval_output and grep_ring_logger are the Elixir ones and won't work on it)"

      mode in [:down, :unknown] ->
        names <> " (device tools error until it is back)"

      true ->
        names
    end
  end

  defp format_ms(nil), do: "unknown"
  defp format_ms(ms), do: "#{div(ms, 1000)}s"

  defp last_probe(nil), do: "never"
  defp last_probe(ms), do: "#{div(ms, 1000)}s ago"
end
