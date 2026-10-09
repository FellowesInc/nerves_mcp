defmodule NervesMCP.CLITest do
  # configure/1 writes the application env, so these can't run concurrently.
  use ExUnit.Case, async: false

  alias NervesMCP.CLI

  setup do
    connection = Application.get_env(:nerves_mcp, :connection)
    devices = Application.get_env(:nerves_mcp, :devices)
    port = Application.get_env(:nerves_mcp, :port)

    Application.delete_env(:nerves_mcp, :connection)
    Application.delete_env(:nerves_mcp, :devices)
    Application.delete_env(:nerves_mcp, :port)

    on_exit(fn ->
      restore(:connection, connection)
      restore(:devices, devices)
      restore(:port, port)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:nerves_mcp, key)
  defp restore(key, value), do: Application.put_env(:nerves_mcp, key, value)

  defp connection(), do: Application.get_env(:nerves_mcp, :connection)

  describe "configure/1 ssh" do
    test "a positional host becomes an ssh connection with the defaults" do
      CLI.configure(["nerves.local"])

      assert Keyword.fetch!(connection(), :type) == :ssh
      assert Keyword.fetch!(connection(), :host) == "nerves.local"
      assert Keyword.fetch!(connection(), :user) == "root"
      assert Keyword.fetch!(connection(), :port) == 22
    end

    test "--user, --ssh-port and --pass land in the connection env" do
      CLI.configure([
        "nerves.local",
        "--user",
        "exnvr",
        "--ssh-port",
        "2222",
        "--pass",
        "hunter2"
      ])

      assert Keyword.fetch!(connection(), :user) == "exnvr"
      assert Keyword.fetch!(connection(), :port) == 2222
      assert Keyword.fetch!(connection(), :pass) == "hunter2"
    end

    test "config alone is enough, and the command line overrides it" do
      Application.put_env(:nerves_mcp, :connection, type: :ssh, host: "configured.local")

      CLI.configure(["--user", "exnvr"])

      assert Keyword.fetch!(connection(), :host) == "configured.local"
      assert Keyword.fetch!(connection(), :user) == "exnvr"
    end
  end

  describe "configure/1 serial" do
    test "a /dev/tty path is auto-detected as uart" do
      CLI.configure(["/dev/ttyUSB0", "--speed", "9600"])

      assert Keyword.fetch!(connection(), :type) == :uart
      assert Keyword.fetch!(connection(), :port) == "/dev/ttyUSB0"
      assert Keyword.fetch!(connection(), :speed) == 9600
    end
  end

  describe "configure/1 --device" do
    test "each --device is a named device, with the shared options on every one" do
      config =
        CLI.configure([
          "--device",
          "board1=192.0.2.10",
          "--device",
          "bench=/dev/ttyUSB0",
          "--user",
          "exnvr"
        ])

      assert [{"board1", board1}, {"bench", bench}] = config.devices
      assert Application.get_env(:nerves_mcp, :devices) == config.devices

      assert Map.new(board1) == %{type: :ssh, host: "192.0.2.10", user: "exnvr", port: 22}

      assert Keyword.fetch!(bench, :type) == :uart
      assert Keyword.fetch!(bench, :port) == "/dev/ttyUSB0"
    end

    test "a single --device keeps its name" do
      assert [{"board2", _connection}] =
               CLI.configure(["--device", "board2=board2.local"]).devices

      assert [{"board2", _connection}] = Application.get_env(:nerves_mcp, :devices)
    end

    test "a single device without --device is the default device" do
      assert [{"default", _connection}] = CLI.configure(["nerves.local"]).devices
      assert Application.get_env(:nerves_mcp, :devices) == nil
    end

    test "configured :devices are used when there is no target, with the overrides" do
      Application.put_env(:nerves_mcp, :devices, [
        {"a", type: :ssh, host: "a.local", user: "root", port: 22}
      ])

      assert [{"a", connection}] = CLI.configure(["--user", "exnvr"]).devices
      assert Keyword.fetch!(connection, :user) == "exnvr"
    end

    test "a malformed --device is rejected" do
      for spec <- ["board2", "=board2.local", "board2="] do
        assert_raise ArgumentError, ~r/invalid --device/, fn ->
          CLI.configure(["--device", spec])
        end
      end
    end

    test "a device name given twice is rejected" do
      assert_raise ArgumentError, ~r/--device a is given more than once/, fn ->
        CLI.configure(["--device", "a=a.local", "--device", "a=b.local"])
      end
    end

    test "--ssh-port leaves a serial device's path alone" do
      config =
        CLI.configure([
          "--device",
          "a=a.local",
          "--device",
          "b=/dev/ttyUSB0",
          "--ssh-port",
          "2222"
        ])

      assert [{"a", ssh}, {"b", serial}] = config.devices
      assert Keyword.fetch!(ssh, :port) == 2222
      assert Keyword.fetch!(serial, :port) == "/dev/ttyUSB0"
    end

    test "--device with a positional target is rejected" do
      assert_raise ArgumentError, ~r/can't be combined/, fn ->
        CLI.configure(["nerves.local", "--device", "board2=board2.local"])
      end
    end
  end

  describe "configure/1 mcp port" do
    test "defaults to 13000" do
      assert CLI.configure(["nerves.local"]).mcp_port == 13_000
      assert Application.get_env(:nerves_mcp, :port) == 13_000
    end

    test "--port overrides the default" do
      assert CLI.configure(["nerves.local", "--port", "14000"]).mcp_port == 14_000
      assert Application.get_env(:nerves_mcp, :port) == 14_000
    end

    test "65535 is accepted" do
      assert CLI.configure(["nerves.local", "--port", "65535"]).mcp_port == 65_535
    end

    test "0 is rejected, since the banner and the claude hint would print it" do
      assert_raise ArgumentError, ~r/invalid MCP port 0, expected an integer in 1\.\.65535/, fn ->
        CLI.configure(["nerves.local", "--port", "0"])
      end
    end

    test "a negative port is rejected and named in the message" do
      assert_raise ArgumentError, ~r/invalid MCP port -1\b/, fn ->
        CLI.configure(["nerves.local", "--port", "-1"])
      end
    end

    test "a port above 65535 is rejected" do
      assert_raise ArgumentError, ~r/invalid MCP port 70000\b/, fn ->
        CLI.configure(["nerves.local", "--port", "70000"])
      end
    end

    test "a nil :port in the config env is rejected" do
      Application.put_env(:nerves_mcp, :port, nil)

      assert_raise ArgumentError, ~r/invalid MCP port nil\b/, fn ->
        CLI.configure(["nerves.local"])
      end
    end

    test "an out-of-range :port in the config env is rejected" do
      Application.put_env(:nerves_mcp, :port, 99_999)

      assert_raise ArgumentError, ~r/invalid MCP port 99999\b/, fn ->
        CLI.configure(["nerves.local"])
      end
    end
  end

  describe "configure/1 starts nothing" do
    # `mix nerves_mcp` relies on this: configure first, then app.start, so the
    # application reads the CLI values instead of starting on the config port.
    test "no children come up but the registry" do
      CLI.configure(["nerves.local", "--port", "13999"])

      assert [{NervesMCP.Registry, _pid, _type, _modules}] =
               Supervisor.which_children(NervesMCP.Supervisor)
    end
  end

  describe "configure/1 --no-repl" do
    test "the repl runs by default" do
      assert CLI.configure(["nerves.local"]).repl? == true
    end

    test "--no-repl turns it off" do
      assert CLI.configure(["nerves.local", "--no-repl"]).repl? == false
    end

    test "--no-repl is not mistaken for a connection setting" do
      config = CLI.configure(["nerves.local", "--no-repl"])

      assert [{"default", connection}] = config.devices
      refute Keyword.has_key?(connection, :no_repl)
    end
  end
end
