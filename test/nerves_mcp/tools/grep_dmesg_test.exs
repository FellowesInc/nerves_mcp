defmodule NervesMCP.Tools.GrepDmesgTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Tools.GrepDmesg

  test "a mode that runs Elixir gets the wrapped evaluator" do
    assert {:eval_output, code} = GrepDmesg.request(:nerves, "modem", false, nil)
    assert code =~ ~s|:os.cmd(~c"dmesg")|
    assert code =~ ~s|pattern = "modem"|
  end

  # The bug: :shell listed grep_dmesg but still built `(fn -> ... end).()`, which
  # a raw shell cannot run.
  test "shell mode gets a dmesg pipeline instead of Elixir" do
    assert {:shell_eval_output, command} = GrepDmesg.request(:shell, "modem", false, nil)
    assert command == "dmesg | grep -F -- 'modem'"
  end

  test "a regex pattern becomes grep -E" do
    assert {:shell_eval_output, command} = GrepDmesg.request(:shell, "mo[dD]em", true, nil)
    assert command == "dmesg | grep -E -- 'mo[dD]em'"
  end

  test "tail becomes a tail pipe" do
    assert {:shell_eval_output, command} = GrepDmesg.request(:shell, "modem", false, 20)
    assert command == "dmesg | grep -F -- 'modem' | tail -n 20"
  end

  # A quote in the pattern would otherwise end the argument and let the rest of
  # it run as shell.
  test "a single quote in the pattern is escaped" do
    assert {:shell_eval_output, command} =
             GrepDmesg.request(:shell, "it's; rm -rf /", false, nil)

    assert command == ~S(dmesg | grep -F -- 'it'\''s; rm -rf /')
  end
end
