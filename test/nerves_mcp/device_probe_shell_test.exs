defmodule NervesMCP.DeviceProbeShellTest do
  # A real SSH session to a shell that echoes and answers but never runs Elixir.
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices
  alias NervesMCP.Test.SSHDaemon

  setup do
    daemon =
      SSHDaemon.start(fn _user, _peer ->
        spawn(fn -> not_elixir() end)
      end)

    previous = Application.get_env(:nerves_mcp, :devices)

    devices = [
      {"sh",
       type: :ssh, host: "127.0.0.1", port: daemon.port, user: System.get_env("USER", "nobody")}
    ]

    Application.put_env(:nerves_mcp, :devices, devices)
    start_supervised!({Devices, devices})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_mcp, :devices, previous),
        else: Application.delete_env(:nerves_mcp, :devices)

      SSHDaemon.stop(daemon)
    end)
  end

  defp not_elixir() do
    case IO.gets("$ ") do
      :eof ->
        :ok

      _line ->
        IO.puts("sh: not found")
        not_elixir()
    end
  end

  test "a shell that never runs Elixir is only called a shell after three probes" do
    assert {:shell, _detail} = DeviceProbe.refresh("sh")
    refute DeviceProbe.mode("sh") == :shell

    assert eventually(fn -> DeviceProbe.mode("sh") == :shell end, 40)
  end

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(500) && eventually(fun, tries - 1)
    end
  end
end
