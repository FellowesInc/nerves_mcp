defmodule NervesMCP.Connection.SSHTest do
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

  test "eval returns the inspected result" do
    assert {:ok, result} = SSH.eval("2 * 3")
    assert String.trim(result) == "6"
  end

  test "eval_output returns what the code printed and its result" do
    assert {:ok, output} = SSH.eval_output(~s|IO.puts("hello from the shell")|)
    assert output =~ "hello from the shell"
  end

  # An exception on the device is still a successful round trip. The wrapper formats it
  # into the reply rather than failing the call.
  test "an exception comes back as ERROR text" do
    assert {:ok, result} = SSH.eval(~s|raise "boom"|)
    assert result =~ "ERROR: ** (RuntimeError) boom"
  end
end
