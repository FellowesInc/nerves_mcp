defmodule NervesMCP do
  @moduledoc """
  MCP Server for interacting with Nerves devices.

  ## Running the Server

  Start with `mix run --no-halt` or `iex -S mix`.

  The MCP server will be available at: `http://localhost:8080/mcp`

  ## Configuration

  Configure in your `config/config.exs`:

  ### HTTP Server Port

      config :nerves_mcp, :port, 8080

  ### UART (Serial) Connection

      config :nerves_mcp, :connection,
        type: :uart,
        port: "/dev/ttyUSB2",
        speed: 115_200

  ### SSH Connection

      config :nerves_mcp, :connection,
        type: :ssh,
        host: "nerves.local",
        user: "root",
        port: 22

  ### Several devices

      config :nerves_mcp, :devices, [
        {"board1", type: :ssh, host: "192.0.2.10"},
        {"board2", type: :ssh, host: "192.0.2.11"}
      ]

  See `NervesMCP.Devices`.

  ## Interactive Console

  Call `NervesMCP.console()` to enter an interactive console session, or
  `NervesMCP.console("board2")` to pick a device when there are several.
  Type `#quit` to exit and return to IEx, or `#history` to view buffered output.

  ## Output History

  Device output that arrives when no console is attached is stored in a
  circular buffer per device. Call `NervesMCP.history()` to view it, or use
  `#history` in the console.
  """

  alias NervesMCP.Devices

  @doc """
  Opens an interactive console to a connected device.

  Displays all incoming data from the device and allows you to send
  commands directly. Type `#quit` to exit the console and return to IEx.
  `device` can be left out when only one device is configured.
  """
  @spec console(Devices.name() | nil) :: :ok | {:error, String.t()}
  def console(device \\ nil) do
    with {:ok, device} <- Devices.resolve(device),
         {:ok, module} <- Devices.module(device) do
      open_console(device, module)
    end
  end

  defp open_console(device, module) do
    # Start a process to receive and display console data
    receiver =
      spawn_link(fn ->
        monitor_and_attach(device, module)
        receive_loop(device, module)
      end)

    IO.puts("Connected to #{device} console. Commands: #quit, #history")
    IO.puts("---")

    try do
      input_loop(device, module)
    after
      # Clean up: stop receiver and detach console
      send(receiver, :stop)
      module.detach_console(device)
    end

    IO.puts("---")
    IO.puts("Console closed.")
    :ok
  end

  @doc """
  Prints the buffered device output history.

  All device output that arrives when no console is attached is stored
  in a circular buffer. Use this to view what you might have missed.
  """
  @spec history(Devices.name() | nil) :: :ok | {:error, String.t()}
  def history(device \\ nil) do
    with {:ok, device} <- Devices.resolve(device) do
      IO.puts(NervesMCP.History.get(device))
    end
  end

  @spec exit() :: no_return()
  def exit() do
    IO.puts("Exiting...")
    System.halt(0)
  end

  defp monitor_and_attach(device, module) do
    pid = wait_for_process(device, module)
    Process.monitor(pid)
    module.attach_console(device, self())
  end

  defp wait_for_process(device, module) do
    case GenServer.whereis(Devices.via(device, module)) do
      nil ->
        Process.sleep(200)
        wait_for_process(device, module)

      pid ->
        pid
    end
  end

  defp receive_loop(device, module, buffer \\ <<>>) do
    receive do
      {:console_data, data} ->
        combined = buffer <> data
        {complete, incomplete} = split_utf8(combined)

        if byte_size(complete) > 0 do
          IO.write(complete)
        end

        receive_loop(device, module, incomplete)

      {:DOWN, _ref, :process, _pid, _reason} ->
        IO.puts("\r\n--- Connection lost, reconnecting... ---")
        monitor_and_attach(device, module)
        IO.puts("--- Reconnected ---")
        receive_loop(device, module)

      :stop ->
        # Write any remaining buffer on exit
        if byte_size(buffer) > 0 do
          IO.write(buffer)
        end

        :ok
    end
  end

  # Split binary into complete UTF-8 characters and trailing incomplete bytes
  defp split_utf8(binary) do
    size = byte_size(binary)

    if size == 0 do
      {<<>>, <<>>}
    else
      # Find how many trailing bytes might be incomplete
      incomplete_count = trailing_incomplete_bytes(binary, size)
      complete_size = size - incomplete_count
      <<complete::binary-size(^complete_size), incomplete::binary>> = binary
      {complete, incomplete}
    end
  end

  # Count trailing bytes that form an incomplete UTF-8 sequence
  defp trailing_incomplete_bytes(binary, size) do
    # Check last 1-4 bytes for incomplete sequence
    check_from = max(0, size - 4)

    size
    |> Range.new(check_from + 1, -1)
    |> Enum.reduce_while(0, fn pos, _acc ->
      idx = pos - 1
      <<_::binary-size(^idx), byte, _rest::binary>> = binary

      classify_trailing_byte(byte, size - idx)
    end)
  end

  # ASCII or valid end of multi-byte - everything complete
  defp classify_trailing_byte(byte, _remaining) when byte <= 127, do: {:halt, 0}

  # Continuation byte (10xxxxxx) - keep looking back
  defp classify_trailing_byte(byte, remaining) when byte in 128..191, do: {:cont, remaining}

  # 2-byte start (110xxxxx) - need 1 more
  defp classify_trailing_byte(byte, remaining) when byte in 192..223,
    do: {:halt, incomplete_count(remaining, 2)}

  # 3-byte start (1110xxxx) - need 2 more
  defp classify_trailing_byte(byte, remaining) when byte in 224..239,
    do: {:halt, incomplete_count(remaining, 3)}

  # 4-byte start (11110xxx) - need 3 more
  defp classify_trailing_byte(byte, remaining) when byte in 240..247,
    do: {:halt, incomplete_count(remaining, 4)}

  # Invalid UTF-8 byte - treat as complete to avoid infinite buffering
  defp classify_trailing_byte(_byte, _remaining), do: {:halt, 0}

  defp incomplete_count(remaining, sequence_length) when remaining < sequence_length,
    do: remaining

  defp incomplete_count(_remaining, _sequence_length), do: 0

  defp input_loop(device, module) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      input when is_binary(input) ->
        trimmed = String.trim_trailing(input, "\n")

        case trimmed do
          "#quit" ->
            :ok

          "#history" ->
            IO.puts("--- History ---")
            IO.puts(NervesMCP.History.get(device))
            IO.puts("--- End History ---")
            input_loop(device, module)

          _ ->
            module.send_raw(device, input)
            input_loop(device, module)
        end
    end
  end
end
