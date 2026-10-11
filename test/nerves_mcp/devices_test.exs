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

  test "describe/1 shows the port and the speed" do
    assert Devices.describe(type: :ssh, host: "nerves.local", user: "root", port: 2222) ==
             "ssh root@nerves.local:2222"

    assert Devices.describe(type: :ssh, host: "nerves.local") == "ssh root@nerves.local:22"

    assert Devices.describe(type: :uart, port: "/dev/ttyUSB0", speed: 9600) ==
             "serial /dev/ttyUSB0 @ 9600"
  end

  test "module_for/1 picks the connection for the type" do
    assert Devices.module_for(type: :ssh, host: "a.local") == NervesMCP.Connection.SSH
    assert Devices.module_for(type: :uart, port: "/dev/ttyUSB0") == NervesMCP.Connection.UART
  end

  # module/1 and connection/1 answer from the running connection, not the config.
  test "a configured device with no running connection says so" do
    configure(["a"])

    assert Devices.module("a") == {:error, ~s|No connection is running for device "a"|}
    assert Devices.connection("a") == []
  end

  test "a running connection answers with its own module and settings" do
    connection = [type: :ssh, host: "a.local"]
    via = Devices.connection_via("a", NervesMCP.Connection.SSH, connection)
    start_supervised!(%{id: :a, start: {Agent, :start_link, [fn -> nil end, [name: via]]}})

    assert Devices.module("a") == {:ok, NervesMCP.Connection.SSH}
    assert Devices.connection("a") == connection
  end

  describe "validate!/1" do
    test "returns good devices" do
      devices = [{"a", type: :ssh, host: "a.local"}, {"b", type: :uart, port: "/dev/ttyUSB0"}]

      assert Devices.validate!(devices) == devices
    end

    test "rejects a name given twice" do
      assert_raise ArgumentError, ~s|device "a" is configured more than once|, fn ->
        Devices.validate!([{"a", type: :ssh, host: "a"}, {"a", type: :ssh, host: "b"}])
      end
    end

    test "rejects a name that isn't a non-empty string" do
      for name <- [:a, ""] do
        assert_raise ArgumentError, ~r/invalid device/, fn ->
          Devices.validate!([{name, type: :ssh, host: "a"}])
        end
      end
    end

    test "rejects a missing or unknown type" do
      for connection <- [[host: "a"], [type: :usb, host: "a"]] do
        assert_raise ArgumentError, ~r/not :ssh or :uart/, fn ->
          Devices.validate!([{"a", connection}])
        end
      end
    end

    test "rejects a type without its address" do
      assert_raise ArgumentError, ~s|device "a" has no :host|, fn ->
        Devices.validate!([{"a", type: :ssh}])
      end

      assert_raise ArgumentError, ~s|device "b" has no :port|, fn ->
        Devices.validate!([{"b", type: :uart}])
      end
    end

    test "rejects settings that aren't a keyword list" do
      assert_raise ArgumentError, ~r/needs a keyword list/, fn ->
        Devices.validate!([{"a", %{type: :ssh}}])
      end
    end
  end
end
