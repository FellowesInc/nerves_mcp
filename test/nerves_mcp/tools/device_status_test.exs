defmodule NervesMCP.Tools.DeviceStatusTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Server
  alias NervesMCP.Tools.DeviceStatus

  test "a shell device on its own gets the shell tools" do
    text = DeviceStatus.offered(:shell, Server.tools_for_all([:shell]))

    assert text =~ "(device_eval takes a shell command in this mode)"
    refute text =~ "grep_ring_logger"
  end

  # The list covers every device, so a shell device next to an Elixir one gets the Elixir tools.
  test "a shell device among Elixir ones is told the listed tools won't work on it" do
    text = DeviceStatus.offered(:shell, Server.tools_for_all([:shell, :nerves]))

    assert text =~ "grep_ring_logger"
    assert text =~ "won't work on it"
    refute text =~ "takes a shell command"
  end

  test "an Elixir device gets the list with no note" do
    listed = Server.tools_for_all([:shell, :nerves])

    assert DeviceStatus.offered(:nerves, listed) == Enum.map_join(listed, ", ", & &1.name())
  end

  test "a down device is told the tools error until it is back" do
    assert DeviceStatus.offered(:down, Server.tools_for_all([:down])) =~
             "(device tools error until it is back)"
  end
end
