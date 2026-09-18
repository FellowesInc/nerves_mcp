defmodule NervesMCP.Test.SSHDaemon do
  @moduledoc """
  A local SSH daemon with an IEx shell, for testing the SSH connection without a device.

  It is the same stack a device runs: Erlang `:ssh` plus IEx, so the line editing and
  echo behavior that `NervesMCP.Connection.SSH` parses is the real thing. The shell
  option is the one nerves_ssh uses on Elixir >= 1.17.

  Authentication is `no_auth_needed`, because sshpass isn't available everywhere and a
  loopback daemon on an ephemeral port needs nothing more.

  ### API

    * `start/0` — start the daemon and return its port
    * `start/1` — the same, with another shell in place of IEx
    * `stop/1` — stop it and remove its host key
    * `connect/1` — start the SSH connection against it and wait for a live IEx
  """

  @type t :: %{ref: :ssh.daemon_ref(), port: :inet.port_number(), system_dir: String.t()}

  @spec start({module(), atom(), list()} | function()) :: t()
  def start(shell \\ {:iex, :start, [[], {:elixir_utils, :noop, []}]}) do
    {:ok, _} = Application.ensure_all_started(:ssh)
    {:ok, _} = Application.ensure_all_started(:iex)

    system_dir = host_key_dir()

    {:ok, ref} =
      :ssh.daemon(:loopback, 0,
        system_dir: to_charlist(system_dir),
        no_auth_needed: true,
        shell: shell
      )

    {:ok, info} = :ssh.daemon_info(ref)

    %{ref: ref, port: Keyword.fetch!(info, :port), system_dir: system_dir}
  end

  @spec stop(t()) :: :ok
  def stop(daemon) do
    :ok = :ssh.stop_daemon(daemon.ref)
    _ = File.rm_rf(daemon.system_dir)
    :ok
  end

  @doc """
  Point `NervesMCP.Connection.SSH` at the daemon and start it, returning its pid.

  Waits for the remote IEx to answer, since the connection's `init/1` returns as soon
  as the ssh port opens. The `:connection` env is application-wide, so it is put back
  when the test ends and the next test doesn't inherit a stopped daemon's port.
  """
  @spec connect(t()) :: pid()
  def connect(daemon) do
    previous = Application.fetch_env(:nerves_mcp, :connection)
    ExUnit.Callbacks.on_exit(fn -> restore_connection(previous) end)

    Application.put_env(:nerves_mcp, :connection,
      type: :ssh,
      host: "127.0.0.1",
      port: daemon.port,
      user: System.get_env("USER", "nobody")
    )

    {:ok, pid} = NervesMCP.Connection.SSH.start_link([])
    await_shell(20)
    pid
  end

  defp restore_connection({:ok, config}),
    do: Application.put_env(:nerves_mcp, :connection, config)

  defp restore_connection(:error), do: Application.delete_env(:nerves_mcp, :connection)

  defp await_shell(0), do: raise("the test daemon's IEx never answered")

  defp await_shell(tries) do
    case NervesMCP.Connection.SSH.eval("1 + 1", 1_000) do
      {:ok, "2" <> _crlf} ->
        :ok

      _not_ready_yet ->
        Process.sleep(250)
        await_shell(tries - 1)
    end
  end

  defp host_key_dir() do
    dir =
      Path.join(System.tmp_dir!(), "nerves_mcp_test_ssh_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    {_output, 0} =
      System.cmd(
        "ssh-keygen",
        [
          "-q",
          "-t",
          "ecdsa",
          "-N",
          "",
          "-C",
          "nerves_mcp test",
          "-f",
          Path.join(dir, "ssh_host_ecdsa_key")
        ],
        stderr_to_stdout: true
      )

    dir
  end
end
