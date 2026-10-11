defmodule NervesMCP.Tools.IsDeviceUp do
  @moduledoc """
  Check if a connected Nerves device is up and responsive.

  Repeatedly attempts to read the device's firmware UUID via
  `Nerves.Runtime.KV.get_active("nerves_fw_uuid")`.
  Returns success with the UUID once the device responds, or an error
  if the total timeout is exceeded.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.Tools.Device

  @eval_timeout 5_000
  @retry_pause 2_000

  @impl EMCP.Tool
  def name(), do: "is_device_up"

  @impl EMCP.Tool
  def description(), do: "Check if the connected Nerves device is up and responsive"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        device: Device.schema(),
        timeout: %{
          type: :integer,
          description: "Total timeout in milliseconds to keep retrying (default: 60000)"
        }
      },
      required: []
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    Device.with_device(args, fn device ->
      total_timeout = args["timeout"] || 60_000
      deadline = System.monotonic_time(:millisecond) + total_timeout

      case poll_device(device, deadline) do
        {:ok, uuid} ->
          EMCP.Tool.response([
            %{"type" => "text", "text" => "Device is up. Firmware UUID: #{uuid}"}
          ])

        {:error, reason} ->
          EMCP.Tool.error(reason)
      end
    end)
  end

  defp poll_device(device, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, timed_out(Device.connection_status(device))}
    else
      eval_timeout = min(@eval_timeout, remaining)

      case try_eval(device, eval_timeout) do
        {:ok, uuid} when uuid != "" ->
          # The device answered, so the probe's cached mode is stale. Without
          # this it stays :down and the device tools keep refusing calls. This
          # poll read what a probe reads, so hand the answer over rather than
          # making it go and look again.
          NervesMCP.DeviceProbe.record_eval(device, uuid)
          {:ok, String.trim(uuid)}

        _ ->
          Process.sleep(min(@retry_pause, max(0, deadline - System.monotonic_time(:millisecond))))
          poll_device(device, deadline)
      end
    end
  end

  defp timed_out(%{reason: reason}) when is_binary(reason),
    do: "Timed out waiting for device to come up. " <> reason

  defp timed_out(_nothing_to_add), do: "Timed out waiting for device to come up"

  defp try_eval(device, timeout) do
    Device.eval_unchecked(device, ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|, timeout)
  end
end
