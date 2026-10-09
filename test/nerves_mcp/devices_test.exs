defmodule NervesMCP.DevicesTest do
  # Reads the application env, so these can't run concurrently.
  use ExUnit.Case, async: false

  alias NervesMCP.Devices

  setup do
    connection = Application.get_env(:nerves_mcp, :connection)
    devices = Application.get_env(:nerves_mcp, :devices)
    Application.delete_env(:nerves_mcp, :connection)
    Application.delete_env(:nerves_mcp, :devices)

    on_exit(fn ->
      restore(:connection, connection)
      restore(:devices, devices)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_mcp, key)
  defp restore(key, value), do: Application.put_env(:nerves_mcp, key, value)

  defp configure(names) do
    Application.put_env(
      :nerves_mcp,
      :devices,
      Enum.map(names, &{&1, type: :ssh, host: "#{&1}.local"})
    )
  end

  test "a single :connection is the device default" do
    Application.put_env(:nerves_mcp, :connection, type: :ssh, host: "nerves.local")

    assert Devices.configured() == [{"default", type: :ssh, host: "nerves.local"}]
  end

  test ":devices wins over :connection" do
    Application.put_env(:nerves_mcp, :connection, type: :ssh, host: "nerves.local")
    configure(["a", "b"])

    assert Devices.names() == ["a", "b"]
  end

  test "a :connection with no type is no device" do
    Application.put_env(:nerves_mcp, :connection, [])

    assert Devices.configured() == []
    assert Devices.resolve(nil) == {:error, "No device is configured"}
  end

  test "no name resolves to the only device" do
    configure(["board2"])

    assert Devices.resolve(nil) == {:ok, "board2"}
  end

  # A call that names no device must not land on one by accident.
  test "no name is an error when there are several" do
    configure(["board1", "board2"])

    assert Devices.resolve(nil) ==
             {:error, "Several devices are configured, so pass device: one of board1, board2"}
  end

  test "a name resolves when it is configured" do
    configure(["board1", "board2"])

    assert Devices.resolve("board2") == {:ok, "board2"}

    assert Devices.resolve("bench") ==
             {:error, ~s|No device named "bench". Configured: board1, board2|}
  end

  test "module/1 picks the connection for the type" do
    configure(["a"])

    assert Devices.module("a") == {:ok, NervesMCP.Connection.SSH}
    assert Devices.module(type: :uart, port: "/dev/ttyUSB0") == {:ok, NervesMCP.Connection.UART}
    assert Devices.module("missing") == {:error, "Unknown connection type: nil"}
  end
end
