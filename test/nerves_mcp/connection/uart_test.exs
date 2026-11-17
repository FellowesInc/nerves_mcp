defmodule NervesMCP.Connection.UARTTest do
  use ExUnit.Case, async: false

  alias NervesMCP.Connection.UART
  alias NervesMCP.Test.WaitInputConsole

  setup do
    start_supervised!({NervesMCP.History, device: "console"})

    start_supervised!(
      {UART,
       device: "console",
       connection: [type: :uart, port: "/dev/console", uart_module: WaitInputConsole]}
    )

    :ok
  end

  # nbtty --wait-input drops everything until a read carries a CR, and drops that
  # read too, so the probe that wakes the console can't get an answer of its own.
  test "a probe wakes a console held by nbtty --wait-input" do
    assert UART.probe("console", 200) in [:noise, :down]
    assert {:ok, result} = UART.probe("console", 1_000)
    assert String.trim(result) == ~s|"0123abcd"|
  end

  # However the line splits the probe into reads, the CR is in the last one, so
  # none of the waking probe reaches IEx to garble the next.
  test "the waking probe never reaches IEx in part" do
    WaitInputConsole.read_size(16)

    assert UART.probe("console", 200) in [:noise, :down]
    assert {:ok, _result} = UART.probe("console", 1_000)
    assert String.starts_with?(WaitInputConsole.typed(), "(fn ->")
  end
end
