defmodule NervesMCP.HistoryTest do
  use ExUnit.Case, async: false

  alias NervesMCP.History

  # Cursor up, erase to end of screen: what IEx sends before redrawing a block.
  @redraw "\e[A\e[J"

  setup do
    start_supervised!(History)
    :ok
  end

  test "a nil cursor reads everything buffered" do
    History.push("first\r\n")
    History.push("second\r\n")

    assert {"first\nsecond", cursor} = History.since(nil)
    assert is_integer(cursor)
  end

  test "the returned cursor reads only what came after it" do
    History.push("first\r\n")
    {_output, cursor} = History.since(nil)

    assert {"", ^cursor} = History.since(cursor)

    History.push("second\r\n")
    assert {"second", later} = History.since(cursor)
    assert later > cursor
  end

  test "an empty buffer still returns a usable cursor" do
    assert {"", cursor} = History.since(nil)
    History.push("after\r\n")

    assert {"after", _} = History.since(cursor)
  end

  # Captured from the harness: the PTY echoes the wrapper, redraws it once
  # unprompted, then the markers fence the result.
  test "the eval wrapper, its markers and the result it fences are filtered out" do
    History.push("""
    iex(4)> (fn ->\r
    ...(4)>   result = try do\r
    ...(4)>     {value, _binding} = Code.eval_string("1 + 41")\r
    ...(4)>   end\r
    ...(4)>   IO.puts("876070A7AA961484_START")\r
    ...(4)>   IO.puts("876070A7AA961484_END")\r
    ...(4)>   :ok\r
    ...(4)> end).()\r
    #{@redraw}iex(4)> (fn ->\r
              result = try do\r
                {value, _binding} = Code.eval_string("1 + 41")\r
              end\r
              IO.puts("876070A7AA961484_START")\r
              IO.puts("876070A7AA961484_END")\r
              :ok\r
            end).()\r
    876070A7AA961484_START\r
    42\r
    876070A7AA961484_END\r
    :ok\r
    iex(5)> \r
    #{@redraw}iex(5)> \r
    nil\r
    """)

    assert {"", _cursor} = History.since(nil)
  end

  test "output printed outside an eval survives the filter" do
    History.push("iex(13)> \b\b\b\b" <> @redraw <> "LATE OUTPUT\r\n" <> "iex(13)> \r\n")

    assert {"LATE OUTPUT", _cursor} = History.since(nil)
  end
end
