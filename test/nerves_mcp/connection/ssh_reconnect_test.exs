defmodule NervesMCP.Connection.SSHReconnectTest do
  use ExUnit.Case, async: false

  alias NervesMCP.Connection.SSH
  alias NervesMCP.Test.SSHDaemon

  @moduletag timeout: 120_000

  setup do
    start_supervised!(NervesMCP.History)
    daemon = SSHDaemon.start()
    on_exit(fn -> File.rm_rf(daemon.system_dir) end)

    SSHDaemon.connect(daemon)

    %{daemon: daemon}
  end

  test "the session comes back after the device goes away and returns", %{daemon: daemon} do
    assert {:ok, "2" <> _} = SSH.eval("1 + 1", 5_000)

    :ok = :ssh.stop_daemon(daemon.ref)

    # The connection has to notice the drop before the daemon is back, otherwise
    # the test proves nothing.
    assert eventually_disconnected(60), "the dropped connection was never noticed"

    ref = restart_daemon(daemon)

    assert eventually_evaluates(60), "the connection never came back"

    :ok = :ssh.stop_daemon(ref)
  end

  defp restart_daemon(daemon) do
    {:ok, ref} =
      :ssh.daemon(:loopback, daemon.port,
        system_dir: to_charlist(daemon.system_dir),
        no_auth_needed: true,
        shell: {:iex, :start, [[], {:elixir_utils, :noop, []}]}
      )

    ref
  end

  defp eventually_disconnected(0), do: false

  defp eventually_disconnected(tries) do
    case SSH.eval("1 + 1", 500) do
      {:ok, "2" <> _} ->
        Process.sleep(100)
        eventually_disconnected(tries - 1)

      _gone ->
        true
    end
  end

  defp eventually_evaluates(0), do: false

  defp eventually_evaluates(tries) do
    case SSH.eval("1 + 1", 1_000) do
      {:ok, "2" <> _} ->
        true

      _not_yet ->
        Process.sleep(500)
        eventually_evaluates(tries - 1)
    end
  end
end
