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
    start_supervised!({DeviceProbe, device: "default"})
    assert DeviceProbe.mode("default") == :unknown

    # Constant traffic keeps the idle timer below @idle_threshold, which used to
    # hold off every probe and leave a recovered device stuck at :down.
    assert :down == touch_until_probed(4_000)
  end

  # No connection is configured, so anything that went and probed would land on
  # :down instead.
  test "a UUID the caller already read sets the mode with no probe of its own" do
    start_supervised!({DeviceProbe, device: "default"})
    assert DeviceProbe.mode("default") == :unknown

    DeviceProbe.record_eval("default", ~s|"0123abcd"\r\n|)

    assert %{mode: :nerves, detail: "firmware UUID 0123abcd"} = DeviceProbe.status("default")
  end

  describe "shell results" do
    # Results land the way a probe's do. The test runs well inside the first tick, so no
    # real probe interleaves.
    defp result(result),
      do: GenServer.cast(NervesMCP.Devices.via("default", DeviceProbe), {:set_result, result})

    defp shell(), do: result({:shell, "serial responded but did not run Elixir"})

    test "one leaves an unknown device unknown" do
      start_supervised!({DeviceProbe, device: "default"})
      shell()

      assert %{mode: :unknown, detail: "output but no Elixir result, 1 of 3 probes in a row"} =
               DeviceProbe.status("default")
    end

    test "three in a row switch to shell" do
      start_supervised!({DeviceProbe, device: "default"})
      for _ <- 1..3, do: shell()

      assert DeviceProbe.mode("default") == :shell
    end

    # The bench case: a Nerves device that answers slowly once must not lose its Elixir tools.
    test "a Nerves device keeps its mode, and an answer resets the count" do
      start_supervised!({DeviceProbe, device: "default"})
      DeviceProbe.record_eval("default", ~s|"0123abcd"|)

      shell()
      shell()
      assert DeviceProbe.mode("default") == :nerves

      DeviceProbe.record_eval("default", ~s|"0123abcd"|)
      shell()
      shell()
      assert DeviceProbe.mode("default") == :nerves

      shell()
      assert DeviceProbe.mode("default") == :shell
    end

    test "a busy result breaks the run but keeps the mode" do
      start_supervised!({DeviceProbe, device: "default"})
      shell()
      shell()
      result({:busy, "device busy (evaluation in flight)"})
      shell()

      assert %{mode: :unknown, detail: "output but no Elixir result, 1 of 3 probes in a row"} =
               DeviceProbe.status("default")
    end
  end

  defp touch_until_probed(budget) do
    deadline = System.monotonic_time(:millisecond) + budget
    touch_until_probed(deadline, DeviceProbe.mode("default"))
  end

  defp touch_until_probed(_deadline, :down), do: :down

  defp touch_until_probed(deadline, mode) do
    if System.monotonic_time(:millisecond) >= deadline do
      mode
    else
      DeviceProbe.touch("default")
      Process.sleep(100)
      touch_until_probed(deadline, DeviceProbe.mode("default"))
    end
  end
end
