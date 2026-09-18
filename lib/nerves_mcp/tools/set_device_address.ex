defmodule NervesMCP.Tools.SetDeviceAddress do
  @moduledoc """
  Give the SSH connection an IP address for a device whose name won't resolve.

  The device on the address has to report the hostname the configured name
  expects before anything runs on it. A match is cached for the next time the
  name goes quiet. The configured name stays primary.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Tools.Device

  @impl EMCP.Tool
  def name(), do: "set_device_address"

  @impl EMCP.Tool
  def description(),
    do:
      "Give the SSH connection the device's IP address, for when its name (e.g. " <>
        "nerves-1234.local) won't resolve. Ask the user for the address. The device on it " <>
        "must report the expected hostname before it is used, and it is then remembered " <>
        "for next time. The configured name stays primary."

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        address: %{type: :string, description: "The device's IP address, e.g. 192.0.2.10"}
      },
      required: [:address]
    }
  end

  @impl EMCP.Tool
  def call(_conn, %{"address" => address}) do
    case Device.set_address(address) do
      {:ok, text} ->
        # The probe still holds the down mode from before there was an address,
        # so without this the next device tool call is refused until its tick.
        DeviceProbe.refresh()
        EMCP.Tool.response([%{"type" => "text", "text" => text}])

      {:error, reason} ->
        EMCP.Tool.error(reason)
    end
  end
end
