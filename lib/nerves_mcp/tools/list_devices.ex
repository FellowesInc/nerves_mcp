defmodule NervesMCP.Tools.ListDevices do
  @moduledoc """
  List the configured devices, so a client knows what to pass as `device`.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices

  @impl EMCP.Tool
  def name(), do: "list_devices"

  @impl EMCP.Tool
  def description(),
    do:
      "List the configured devices by name, with each one's connection and detected mode. " <>
        "Pass a name as `device` to the other tools."

  @impl EMCP.Tool
  def input_schema(), do: %{type: :object, properties: %{}, required: []}

  @impl EMCP.Tool
  def call(_conn, _args) do
    text =
      case Devices.configured() do
        [] -> "No device is configured."
        devices -> Enum.map_join(devices, "\n", &line/1)
      end

    EMCP.Tool.response([%{"type" => "text", "text" => text}])
  end

  defp line({name, connection}),
    do: "#{name}: #{target(connection)} (#{DeviceProbe.mode(name)})"

  defp target(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart -> "serial #{Keyword.fetch!(connection, :port)}"
      :ssh -> "ssh #{Keyword.get(connection, :user, "root")}@#{Keyword.fetch!(connection, :host)}"
    end
  end
end
