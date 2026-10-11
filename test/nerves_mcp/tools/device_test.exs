defmodule NervesMCP.Tools.DeviceTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Tools.Device

  # A configured device with no connection running, so a probe classifies as
  # :down without touching any hardware.
  setup do
    previous = Application.get_env(:nerves_mcp, :connection)
    Application.put_env(:nerves_mcp, :connection, type: :ssh, host: "nerves.local")
    on_exit(fn -> Application.put_env(:nerves_mcp, :connection, previous || []) end)
    :ok
  end

  test "a mode of :unknown refuses the call" do
    assert {:error, message} = Device.ensure_up("default")
    assert message == "Device is down (mode: unknown). Call is_device_up to wait for it."
  end

  test "a probed :down device refuses the call and names the mode" do
    start_supervised!({DeviceProbe, device: "default"})
    assert {:down, _detail} = DeviceProbe.refresh("default")
    assert DeviceProbe.mode("default") == :down

    assert Device.eval("default", "1 + 1", 100) ==
             {:error, "Device is down (mode: down). Call is_device_up to wait for it."}
  end

  test "the device tools surface the down state as a tool error" do
    start_supervised!({DeviceProbe, device: "default"})
    DeviceProbe.refresh("default")

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
