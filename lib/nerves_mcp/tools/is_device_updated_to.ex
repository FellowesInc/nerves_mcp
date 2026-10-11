defmodule NervesMCP.Tools.IsDeviceUpdatedTo do
  @moduledoc """
  Check if a connected Nerves device has been updated to a specific firmware version.

  Repeatedly attempts to read the device's firmware UUID via
  `Nerves.Runtime.KV.get_active("nerves_fw_uuid")` and compares it to the
  expected UUID. Returns success if the UUID matches, an error if the device
  came up with a different UUID (reverted), or an error if the total timeout
  is exceeded.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.Tools.Device

  @eval_timeout 5_000
  @retry_pause 2_000

  @impl EMCP.Tool
  def name(), do: "is_device_updated_to"

  @impl EMCP.Tool
  def description(),
    do: "Check if the connected Nerves device has been updated to a specific firmware version"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        device: Device.schema(),
        expected_uuid: %{
          type: :string,
          description: "The firmware UUID expected after the update"
        },
        timeout: %{
          type: :integer,
          description: "Total timeout in milliseconds to keep retrying (default: 60000)"
        }
      },
      required: [:expected_uuid]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    Device.with_device(args, fn device ->
      expected_uuid = args["expected_uuid"]
      total_timeout = args["timeout"] || 60_000
      deadline = System.monotonic_time(:millisecond) + total_timeout

      case poll_device(device, expected_uuid, deadline) do
        :ok ->
          EMCP.Tool.response([
            %{
              "type" => "text",
              "text" => "Device is up and running expected firmware UUID: #{expected_uuid}"
            }
          ])

        {:error, reason} ->
          EMCP.Tool.error(reason)
      end
    end)
  end

  defp poll_device(device, expected_uuid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "Timed out waiting for device to come up with expected firmware UUID"}
    else
      eval_timeout = min(@eval_timeout, remaining)

      case try_eval(device, eval_timeout) do
        {:ok, raw_uuid} when raw_uuid != "" ->
          # The device answered, so the probe's cached mode is stale. Without
          # this it stays :down and the device tools keep refusing calls. This
          # poll read what a probe reads, so hand the answer over rather than
          # making it go and look again.
          NervesMCP.DeviceProbe.record_eval(device, raw_uuid)
          compare_uuid(raw_uuid, expected_uuid)

        _ ->
          Process.sleep(min(@retry_pause, max(0, deadline - System.monotonic_time(:millisecond))))
          poll_device(device, expected_uuid, deadline)
      end
    end
  end

  defp compare_uuid(raw_uuid, expected_uuid) do
    actual_uuid = raw_uuid |> String.trim() |> String.trim(~s|"|)

    if actual_uuid == expected_uuid do
      :ok
    else
      {:error,
       "Device came up with firmware UUID #{actual_uuid}, expected #{expected_uuid} — firmware may have reverted"}
    end
  end

  defp try_eval(device, timeout) do
    Device.eval_unchecked(device, ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|, timeout)
  end
end
