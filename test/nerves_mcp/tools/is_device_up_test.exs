defmodule NervesMCP.Tools.IsDeviceUpTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.IsDeviceUp

  setup do
    start_supervised!(NervesMCP.History)
    daemon = SSHDaemon.start()
    on_exit(fn -> SSHDaemon.stop(daemon) end)

    SSHDaemon.connect(daemon)
    start_supervised!(DeviceProbe)

    :ok
  end

  # The harness has no Nerves.Runtime, so the UUID read comes back as ERROR text
  # and the probe classifies it as :elixir. Either way the device answered.
  test "a successful poll refreshes the probe" do
    assert DeviceProbe.mode() == :unknown

    assert %{"content" => [%{"text" => text}]} = IsDeviceUp.call(nil, %{"timeout" => 5_000})
    assert text =~ "Device is up"

    assert DeviceProbe.mode() == :elixir
  end
end
