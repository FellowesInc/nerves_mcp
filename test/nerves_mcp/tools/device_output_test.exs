defmodule NervesMCP.Tools.DeviceOutputTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.History
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.DeviceEval
  alias NervesMCP.Tools.DeviceOutput

  setup do
    start_supervised!(History)
    daemon = SSHDaemon.start()
    on_exit(fn -> SSHDaemon.stop(daemon) end)

    SSHDaemon.connect(daemon)
    start_supervised!(DeviceProbe)
    DeviceProbe.refresh()

    :ok
  end

  # The harness prints into the same session a device does, which is the case
  # being tested: device_eval returns the pid, the output lands 300 ms later.
  test "output from a process spawned by device_eval comes back" do
    {_caught_up, cursor} = History.since(nil)

    assert %{"content" => [%{"text" => eval}]} =
             DeviceEval.call(nil, %{
               "code" => ~s|spawn(fn -> Process.sleep(300); IO.puts("LATE OUTPUT") end)|
             })

    assert eval =~ "#PID<"
    refute eval =~ "LATE OUTPUT"

    text = await_output(cursor, 5_000)

    assert text =~ "LATE OUTPUT"
    refute text =~ "Code.eval_string"
    refute text =~ "_START"
    assert text =~ ~r/cursor: -?\d+/
  end

  # The probe's own eval keeps printing into the session, so the cursor moves on
  # even when everything it consumed was protocol.
  test "a cursor with nothing after it says so and hands a cursor back" do
    {_caught_up, cursor} = History.since(nil)

    assert %{"content" => [%{"text" => text}]} = DeviceOutput.call(nil, %{"cursor" => cursor})
    assert [head, next] = String.split(text, "\n\ncursor: ")
    assert head == "No device output since the last cursor."
    assert String.to_integer(next) >= cursor
  end

  defp await_output(cursor, budget) do
    deadline = System.monotonic_time(:millisecond) + budget
    await_output(cursor, deadline, "")
  end

  defp await_output(cursor, deadline, last) do
    %{"content" => [%{"text" => text}]} = DeviceOutput.call(nil, %{"cursor" => cursor})

    cond do
      text =~ "LATE OUTPUT" -> text
      System.monotonic_time(:millisecond) >= deadline -> last
      true -> Process.sleep(100) && await_output(cursor, deadline, text)
    end
  end
end
