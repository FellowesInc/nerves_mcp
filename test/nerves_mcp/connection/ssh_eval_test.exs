defmodule NervesMCP.Connection.SSHEvalTest do
  use ExUnit.Case, async: false

  alias NervesMCP.Connection.SSH
  alias NervesMCP.Test.SSHDaemon

  setup do
    start_supervised!(NervesMCP.History)
    daemon = SSHDaemon.start()
    on_exit(fn -> SSHDaemon.stop(daemon) end)

    SSHDaemon.connect(daemon)

    %{daemon: daemon}
  end

  # The size that used to time out. A single line that long is truncated by the
  # remote line editor and reaches the compiler as `"aaa..." <> ...`.
  test "a 20 KB eval comes back" do
    code = generated_code(20_000)
    assert byte_size(code) > 19_000

    assert {:ok, result} = SSH.eval(code, 15_000)
    assert String.trim(result) == ":generated_ok"
  end

  test "code with quotes and non-UTF8 bytes comes back" do
    code = ~S|{"a\"b", <<0xFF, 0xFE>>}|

    assert {:ok, result} = SSH.eval(code)
    assert result =~ ~S|{"a\"b", <<255, 254>>}|
  end

  test "eval_output keeps working through the base64 payload" do
    assert {:ok, output} = SSH.eval_output(~s|IO.puts("printed")\n:returned|)

    assert output =~ "printed"
    assert output =~ ":returned"
  end

  defp generated_code(size) do
    line = ~s|  _ = "#{String.duplicate("a", 60)}"\n|

    "(fn ->\n" <> String.duplicate(line, div(size, byte_size(line))) <> "  :generated_ok\nend).()"
  end
end
