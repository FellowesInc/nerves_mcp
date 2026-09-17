defmodule NervesMCP.Connection.EvalTemplateTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Connection.EvalTemplate
  alias NervesMCP.Connection.EvalTemplate.Matcher

  describe "wrapping" do
    test "the wrapped code prints the markers around the result" do
      wrapped = EvalTemplate.eval(~s|IO.puts("hi")|, "ABCD")

      assert wrapped =~ ~s|IO.puts("ABCD_START")|
      assert wrapped =~ ~s|IO.puts("ABCD_END")|
      assert wrapped =~ "Code.eval_string("
    end

    test "markers are 16 hex characters and do not repeat" do
      marker = EvalTemplate.marker()

      assert marker =~ ~r/^[0-9A-F]{16}$/
      refute marker == EvalTemplate.marker()
    end

    test "shell wrapping stays plain shell" do
      assert EvalTemplate.shell_eval("uname -a", "ABCD") ==
               "echo 'ABCD_START'\nuname -a\necho 'ABCD_END'\n"

      assert EvalTemplate.shell_eval_output("uname -a", "ABCD") =~ "uname -a 2>&1"
    end
  end

  describe "matching elixir output" do
    test "picks the result out from between the markers" do
      assert {:done, "6\r\n"} = feed(matcher(), ["ABCD_START\r\n6\r\nABCD_END\r\n"])
    end

    test "a marker split across two chunks still matches" do
      assert {:done, "6\r\n"} = feed(matcher(), ["ABCD_ST", "ART\r\n6\r\nABCD_", "END\r\n"])
    end

    test "matches byte by byte" do
      chunks = for <<byte <- "ABCD_START\r\n6\r\nABCD_END\r\n">>, do: <<byte>>

      assert {:done, "6\r\n"} = feed(matcher(), chunks)
    end

    # The pty echoes everything that was typed, so the source line holding the
    # marker comes back before the device prints it.
    test "the echo of the sent code is skipped" do
      echo = ~s|  IO.puts("ABCD_START")\r\n  IO.puts("ABCD_END")\r\n|

      assert {:done, "42\r\n"} =
               feed(matcher(), [echo, "ABCD_START\r\n42\r\nABCD_END\r\n"])
    end

    test "output spanning many chunks is collected whole" do
      chunks = ["ABCD_START\r\n"] ++ List.duplicate("noise\r\n", 100) ++ ["ABCD_END\r\n"]

      assert {:done, result} = feed(matcher(), chunks)
      assert result == String.duplicate("noise\r\n", 100)
    end

    test "the UART anchor matches the newline before the marker" do
      uart = Matcher.new("ABCD", :elixir, anchor: :leading)

      assert {:done, "6\r"} = feed(uart, ["junk\nABCD_START\r6\r\nABCD_END\r\n"])
    end
  end

  describe "matching shell output" do
    test "strips the newlines the echo leaves behind" do
      shell = Matcher.new("ABCD", :shell)

      assert {:done, "Linux"} = feed(shell, ["ABCD_START\r\nLinux\r\nABCD_END"])
    end
  end

  describe "output?/1" do
    test "is false until something other than whitespace arrives" do
      {:cont, matcher} = Matcher.feed(matcher(), "\r\n \r\n")
      refute Matcher.output?(matcher)

      {:cont, matcher} = Matcher.feed(matcher, "some noise")
      assert Matcher.output?(matcher)
    end
  end

  defp matcher(), do: Matcher.new("ABCD", :elixir)

  defp feed(matcher, chunks) do
    Enum.reduce_while(chunks, {:cont, matcher}, fn chunk, {:cont, matcher} ->
      case Matcher.feed(matcher, chunk) do
        {:done, result} -> {:halt, {:done, result}}
        {:cont, matcher} -> {:cont, {:cont, matcher}}
      end
    end)
  end
end
