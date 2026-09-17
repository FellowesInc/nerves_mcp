defmodule NervesMCP.Tools.DeviceTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Tools.Device

  # No connection type configured, so a probe classifies as :down without
  # touching any hardware.
  setup do
    previous = Application.get_env(:nerves_mcp, :connection)
    Application.put_env(:nerves_mcp, :connection, [])
    on_exit(fn -> Application.put_env(:nerves_mcp, :connection, previous || []) end)
    :ok
  end

  test "a mode of :unknown refuses the call" do
    assert {:error, message} = Device.ensure_up()
    assert message == "Device is down (mode: unknown). Call is_device_up to wait for it."
  end

  test "a probed :down device refuses the call and names the mode" do
    start_supervised!(DeviceProbe)
    assert {:down, _detail} = DeviceProbe.refresh()
    assert DeviceProbe.mode() == :down

    assert Device.eval("1 + 1", 100) ==
             {:error, "Device is down (mode: down). Call is_device_up to wait for it."}
  end

  test "the device tools surface the down state as a tool error" do
    start_supervised!(DeviceProbe)
    DeviceProbe.refresh()

    for {tool, args} <- [
          {NervesMCP.Tools.DeviceEval, %{"code" => "1 + 1"}},
          {NervesMCP.Tools.DeviceEvalOutput, %{"code" => "1 + 1"}},
          {NervesMCP.Tools.GrepRingLogger, %{"pattern" => "boom"}},
          {NervesMCP.Tools.GrepDmesg, %{"pattern" => "boom"}},
          {NervesMCP.Tools.ShellEval, %{"command" => "uptime"}},
          {NervesMCP.Tools.ShellEvalOutput, %{"command" => "uptime"}}
        ] do
      assert %{"content" => [%{"text" => text}], "isError" => true} = tool.call(nil, args)
      assert text == "Device is down (mode: down). Call is_device_up to wait for it."
    end
  end
end
