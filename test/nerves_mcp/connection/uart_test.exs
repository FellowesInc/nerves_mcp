defmodule NervesMCP.Connection.UARTTest do
  use ExUnit.Case, async: false

  alias NervesMCP.Connection.UART

  @console Path.expand("../../support/wait_input_console.py", __DIR__)

  # The console is a pty that a Python script plays the device on. The port is
  # linked to the test process, so the script exits with the test.
  setup do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        {:line, 256},
        args: [@console]
      ])

    path =
      receive do
        {^port, {:data, {:eol, path}}} -> path
      after
        5_000 -> flunk("the console script printed no pty")
      end

    start_supervised!({NervesMCP.History, device: "console"})
    start_supervised!({UART, device: "console", connection: [type: :uart, port: path]})
    :ok
  end

  # nbtty --wait-input drops everything until a read carries a CR, and drops that
  # read too, so the probe that wakes the console can't get an answer of its own.
  test "a probe wakes a console held by nbtty --wait-input" do
    assert UART.probe("console", 1_000) in [:noise, :down]
    assert {:ok, result} = UART.probe("console", 1_000)
    assert String.trim(result) == ~s|"0123abcd"|
  end
end
