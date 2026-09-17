defmodule NervesMCP.ServerTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Server

  defp names(mode), do: mode |> Server.tools_for() |> Enum.map(& &1.name()) |> Enum.sort()

  @elixir_modes [:nerves, :elixir, :down, :unknown]

  test "every mode that could be running Elixir lists the same tool names" do
    expected =
      Enum.sort([
        "device_eval",
        "device_eval_output",
        "device_output",
        "device_status",
        "grep_dmesg",
        "grep_ring_logger",
        "is_device_up",
        "is_device_updated_to"
      ])

    for mode <- @elixir_modes do
      assert names(mode) == expected, "#{mode} listed #{inspect(names(mode))}"
    end
  end

  # grep_ring_logger needs a running Elixir, so listing it against a serial that
  # has none advertises work it cannot do. grep_dmesg only needs `dmesg` and
  # dispatches through the shell, so it stays.
  test "shell mode drops grep_ring_logger and keeps grep_dmesg" do
    assert names(:shell) ==
             Enum.sort([
               "device_eval",
               "device_eval_output",
               "device_output",
               "device_status",
               "grep_dmesg",
               "is_device_up",
               "is_device_updated_to"
             ])
  end

  # The regression this list fixes: after a reboot device_eval vanished from the
  # client's list and never came back.
  test "a down device still lists the eval and grep tools" do
    for mode <- [:down, :unknown] do
      assert NervesMCP.Tools.DeviceEval in Server.tools_for(mode)
      assert NervesMCP.Tools.DeviceEvalOutput in Server.tools_for(mode)
      assert NervesMCP.Tools.GrepRingLogger in Server.tools_for(mode)
      assert NervesMCP.Tools.GrepDmesg in Server.tools_for(mode)
    end
  end

  test "shell mode swaps in the raw shell implementations" do
    tools = Server.tools_for(:shell)

    assert NervesMCP.Tools.ShellEval in tools
    assert NervesMCP.Tools.ShellEvalOutput in tools
    refute NervesMCP.Tools.DeviceEval in tools
    refute NervesMCP.Tools.DeviceEvalOutput in tools
  end
end
