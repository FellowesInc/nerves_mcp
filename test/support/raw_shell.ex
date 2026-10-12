defmodule NervesMCP.Test.RawShell do
  @moduledoc """
  An SSH channel that answers every eval with the same raw bytes, for the cases IEx
  can't produce. IEx over `:ssh` encodes all of its output, so a byte that isn't
  UTF-8 never reaches the wire the way line noise on a serial console does.

  Each line that carries an eval's END marker, from the Elixir wrapper or the shell
  one, is answered with the START marker, the reply and the END marker. Nothing is
  echoed. Start it with `NervesMCP.Test.SSHDaemon.start({:ssh_cli, {RawShell, [reply]}})`.
  """

  @behaviour :ssh_server_channel

  @end_marker ~r/([0-9A-F]{16})_END/

  @impl :ssh_server_channel
  def init([reply]), do: {:ok, %{reply: reply, buffer: "", channel: nil}}

  @impl :ssh_server_channel
  def handle_msg({:ssh_channel_up, channel, _cm}, state), do: {:ok, %{state | channel: channel}}
  def handle_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def handle_ssh_msg({:ssh_cm, cm, {:data, channel, 0, data}}, state) do
    {lines, [rest]} = (state.buffer <> data) |> String.split(["\r", "\n"]) |> Enum.split(-1)

    for line <- lines, [_line, marker] <- [Regex.run(@end_marker, line)] do
      :ssh_connection.send(cm, channel, "#{marker}_START\r\n#{state.reply}#{marker}_END\r\n")
    end

    {:ok, %{state | buffer: rest}}
  end

  def handle_ssh_msg({:ssh_cm, cm, {request, channel, want_reply, _args}}, state)
      when request in [:pty, :env] do
    :ssh_connection.reply_request(cm, want_reply, :success, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:shell, channel, want_reply}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :success, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel}}, state), do: {:ok, state}
  def handle_ssh_msg({:ssh_cm, _cm, {:closed, channel}}, state), do: {:stop, channel, state}
  def handle_ssh_msg(_msg, state), do: {:ok, state}

  @impl :ssh_server_channel
  def terminate(_reason, _state), do: :ok
end
