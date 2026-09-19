defmodule NervesMCP.Tools.DeviceStatus do
  @moduledoc """
  Report what the device probe currently detects on the other end of the
  connection, and therefore which tools are being offered.

  Always available. Pass `refresh: true` to run a fresh probe now instead of
  reading the last cached result.
  """

  @behaviour EMCP.Tool

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
    if args["refresh"], do: NervesMCP.DeviceProbe.refresh()

    status = NervesMCP.DeviceProbe.status()

    text = """
    Detected mode: #{status.mode}
    Detail: #{status.detail}
    Offered tools: #{offered(status.mode)}
    Idle: #{format_ms(status.idle_ms)}
    Last probe: #{last_probe(status.last_probe_ms_ago)}
    """

    text = text <> connection(Device.connection_status())

    EMCP.Tool.response([%{"type" => "text", "text" => String.trim_trailing(text)}])
  end

  defp connection(nil), do: ""

  defp connection(status) do
    "SSH target: #{status.target}\n" <>
      line("Known address", status.address) <> line("Reason", status.reason)
  end

  defp line(_label, nil), do: ""
  defp line(label, value), do: "#{label}: #{value}\n"

  defp offered(mode) do
    names =
      mode
      |> NervesMCP.Server.tools_for()
      |> Enum.map_join(", ", & &1.name())

    case mode do
      :shell -> names <> " (device_eval takes a shell command in this mode)"
      mode when mode in [:down, :unknown] -> names <> " (device tools error until it is back)"
      _other -> names
    end
  end

  defp format_ms(nil), do: "unknown"
  defp format_ms(ms), do: "#{div(ms, 1000)}s"

  defp last_probe(nil), do: "never"
  defp last_probe(ms), do: "#{div(ms, 1000)}s ago"
end
