defmodule NervesMCP.DeviceProbeTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe

  # No connection type configured, so a probe classifies as :down without
  # touching any hardware.
  setup do
    previous = Application.get_env(:nerves_mcp, :connection)
    Application.put_env(:nerves_mcp, :connection, [])
    on_exit(fn -> Application.put_env(:nerves_mcp, :connection, previous || []) end)
    :ok
  end

  test "a down device is probed even while MCP traffic keeps arriving" do
    start_supervised!(DeviceProbe)
    assert DeviceProbe.mode() == :unknown

    # Constant traffic keeps the idle timer below @idle_threshold, which used to
    # hold off every probe and leave a recovered device stuck at :down.
    assert :down == touch_until_probed(4_000)
  end

  # No connection is configured, so anything that went and probed would land on
  # :down instead.
  test "a UUID the caller already read sets the mode with no probe of its own" do
    start_supervised!(DeviceProbe)
    assert DeviceProbe.mode() == :unknown

    DeviceProbe.record_eval(~s|"0123abcd"\r\n|)

    assert %{mode: :nerves, detail: "firmware UUID 0123abcd"} = DeviceProbe.status()
  end

  defp touch_until_probed(budget) do
    deadline = System.monotonic_time(:millisecond) + budget
    touch_until_probed(deadline, DeviceProbe.mode())
  end

  defp touch_until_probed(_deadline, :down), do: :down

  defp touch_until_probed(deadline, mode) do
    if System.monotonic_time(:millisecond) >= deadline do
      mode
    else
      DeviceProbe.touch()
      Process.sleep(100)
      touch_until_probed(deadline, DeviceProbe.mode())
    end
  end
end
