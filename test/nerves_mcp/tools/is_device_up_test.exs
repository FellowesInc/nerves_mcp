defmodule NervesMCP.Tools.IsDeviceUpTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.History
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.IsDeviceUp

  setup do
    start_supervised!(History)
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

  # The poll already read what a probe reads, so only its own eval should cross
  # the link. A second probe here would spend another 4 s past the caller's
  # deadline and could contradict the poll that just succeeded.
  test "a successful poll updates the mode without a second probe" do
    History.clear()

    assert %{"content" => [%{"text" => _text}]} = IsDeviceUp.call(nil, %{"timeout" => 5_000})
    assert DeviceProbe.mode() == :elixir

    assert evals(History.get()) == 1
  end

  # Each eval and each probe carries its own marker, so counting the distinct
  # ones counts the round trips.
  defp evals(session) do
    ~r/\b([0-9A-F]{16})_START\b/
    |> Regex.scan(session)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> length()
  end
end
