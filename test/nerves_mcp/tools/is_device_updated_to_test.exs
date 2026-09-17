defmodule NervesMCP.Tools.IsDeviceUpdatedToTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.History
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.IsDeviceUpdatedTo

  setup do
    start_supervised!(History)
    daemon = SSHDaemon.start()
    on_exit(fn -> SSHDaemon.stop(daemon) end)

    SSHDaemon.connect(daemon)
    start_supervised!(DeviceProbe)

    :ok
  end

  # The harness has no Nerves.Runtime, so the UUID read comes back as ERROR text
  # and never matches. The device still answered, which is what the probe needs.
  # A second probe here would spend another 4 s past the caller's deadline and
  # could contradict the poll that just succeeded.
  test "a poll that answers updates the mode without a second probe" do
    assert DeviceProbe.mode() == :unknown
    History.clear()

    assert %{"isError" => true} =
             IsDeviceUpdatedTo.call(nil, %{
               "expected_uuid" => "0123abcd",
               "timeout" => 5_000
             })

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
