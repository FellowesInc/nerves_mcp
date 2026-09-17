defmodule NervesMCP.Connection.SSHFallbackTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NervesMCP.Connection.SSH

  @moduletag timeout: 60_000

  setup do
    start_supervised!(NervesMCP.History)
    on_exit(fn -> Application.delete_env(:nerves_mcp, :connection) end)
    :ok
  end

  # Nothing is listening, so ssh exits 255 every time and no device output ever
  # arrives. Every attempt is then a first attempt.
  test "attempts alternate between host and fallback_host, backing off as they go" do
    Application.put_env(:nerves_mcp, :connection,
      type: :ssh,
      host: "127.0.0.1",
      fallback_host: "localhost",
      port: closed_port(),
      user: "nobody"
    )

    log = capture_log(fn -> run_for(4_000) end)

    assert ["127.0.0.1", "localhost" | _] =
             logged(log, ~r/SSH connection started to nobody@(\S+):/)

    assert ["2000", "4000" | _] = logged(log, ~r/Scheduling SSH reconnection in (\d+)ms/)
  end

  test "without a fallback_host every attempt goes to host" do
    Application.put_env(:nerves_mcp, :connection,
      type: :ssh,
      host: "127.0.0.1",
      port: closed_port(),
      user: "nobody"
    )

    log = capture_log(fn -> run_for(4_000) end)

    assert ["127.0.0.1", "127.0.0.1" | _] =
             logged(log, ~r/SSH connection started to nobody@(\S+):/)
  end

  defp run_for(duration) do
    pid = start_supervised!(SSH)
    Process.sleep(duration)
    stop_supervised!(SSH)
    refute Process.alive?(pid)
  end

  defp logged(log, regex) do
    regex |> Regex.scan(log) |> Enum.map(&List.last/1)
  end

  defp closed_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    port
  end
end
