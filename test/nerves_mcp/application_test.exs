defmodule NervesMCP.ApplicationTest do
  use ExUnit.Case, async: false

  @initialize ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}})

  describe "children/2" do
    test "a stop doesn't wait out an open GET /mcp stream" do
      [_devices, bandit] = NervesMCP.Application.children([], 0)
      server = start_supervised!(Supervisor.child_spec(bandit, id: :bandit))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      session = initialize(port)
      stream = open_stream(port, session)

      {elapsed_us, :ok} = :timer.tc(fn -> stop_supervised(:bandit) end)

      # ThousandIsland's default would hold the stop for 15 s.
      assert elapsed_us < 5_000_000
      :gen_tcp.close(stream)
    end
  end

  defp initialize(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n",
        "accept: application/json, text/event-stream\r\n",
        "content-length: #{byte_size(@initialize)}\r\nconnection: close\r\n\r\n",
        @initialize
      ])

    {:ok, response} = recv_all(socket, "")
    [_, session] = Regex.run(~r/mcp-session-id: ([^\r]+)/i, response)
    session
  end

  defp open_stream(port, session) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET /mcp HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n" <>
          "mcp-session-id: #{session}\r\n\r\n"
      )

    {:ok, headers} = :gen_tcp.recv(socket, 0, 2_000)
    assert headers =~ "200"
    socket
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
