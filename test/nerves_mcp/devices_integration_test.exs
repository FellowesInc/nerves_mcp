defmodule NervesMCP.DevicesIntegrationTest do
  # Starts the device supervisor against two local SSH daemons, one per device.
  use ExUnit.Case, async: false

  alias NervesMCP.Connection.SSH
  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools

  setup do
    previous = Application.get_env(:nerves_mcp, :devices)

    daemons = %{"a" => SSHDaemon.start(), "b" => SSHDaemon.start()}

    devices =
      for {name, daemon} <- daemons do
        {name,
         type: :ssh, host: "127.0.0.1", port: daemon.port, user: System.get_env("USER", "nobody")}
      end

    Application.put_env(:nerves_mcp, :devices, devices)
    start_supervised!({Devices, devices})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_mcp, :devices, previous),
        else: Application.delete_env(:nerves_mcp, :devices)

      # One test stops a daemon itself.
      for {_name, daemon} <- daemons,
          :ssh.daemon_info(daemon.ref) != {:error, :bad_daemon_ref},
          do: SSHDaemon.stop(daemon)
    end)

    for name <- Map.keys(daemons), do: await_up(name, 40)

    %{daemons: daemons}
  end

  defp await_up(_name, 0), do: flunk("a device never came up")

  defp await_up(name, tries) do
    case DeviceProbe.refresh(name) do
      {:elixir, _detail} ->
        :ok

      _not_yet ->
        Process.sleep(250)
        await_up(name, tries - 1)
    end
  end

  defp text(%{"content" => [%{"text" => text}]}), do: text

  test "each device evaluates on its own connection" do
    assert {:ok, "2" <> _} = SSH.eval("a", "1 + 1")
    assert {:ok, "6" <> _} = SSH.eval("b", "2 * 3")
  end

  test "a tool call names its device", %{daemons: daemons} do
    assert text(Tools.DeviceEval.call(nil, %{"device" => "b", "code" => "40 + 2"})) =~ "42"

    SSHDaemon.stop(daemons["b"])

    assert %{"isError" => true} = Tools.DeviceEval.call(nil, %{"device" => "b", "code" => "1"})
    assert text(Tools.DeviceEval.call(nil, %{"device" => "a", "code" => "1 + 1"})) =~ "2"
  end

  test "a tool call with no device is refused when there are several" do
    assert %{"isError" => true} = result = Tools.DeviceEval.call(nil, %{"code" => "1 + 1"})

    assert text(result) ==
             "Several devices are configured, so pass device: one of a, b"
  end

  # Printed after the eval returns, so it isn't the fenced result, which the
  # history filters out.
  test "each device keeps its own output history" do
    {:ok, _} = SSH.eval("a", ~s|spawn(fn -> Process.sleep(200); IO.puts("only on a") end)|)

    assert eventually(fn ->
             text(Tools.DeviceOutput.call(nil, %{"device" => "a"})) =~ "only on a"
           end)

    refute text(Tools.DeviceOutput.call(nil, %{"device" => "b"})) =~ "only on a"
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  # Both daemons are on 127.0.0.1, so only the port tells them apart.
  test "list_devices names every device with its connection and mode", %{daemons: daemons} do
    listed = text(Tools.ListDevices.call(nil, %{}))

    for {name, daemon} <- daemons do
      assert listed =~ ~r/^#{name}: ssh \S+@127\.0\.0\.1:#{daemon.port} \(elixir\)$/m
    end
  end

  test "a tool call counts as activity for its own device only" do
    Process.sleep(1_100)

    Tools.DeviceStatus.call(nil, %{"device" => "a"})

    assert DeviceProbe.status("a").idle_ms < 1_000
    assert DeviceProbe.status("b").idle_ms >= 1_000
  end
end
