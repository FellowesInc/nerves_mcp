defmodule NervesMCP.Tools.GrepDmesg do
  @moduledoc """
  Grep the kernel ring buffer (`dmesg`) on the connected device.

  Runs `dmesg` via `:os.cmd/1` on the device, splits the output into lines,
  and returns lines matching the given pattern. Optionally limits the
  output to the last N matches.

  In `:shell` mode there is no Elixir to run that in, so the same work goes
  over as a `dmesg | grep` pipeline instead. `dmesg` is all this tool needs, so
  a serial that only has a shell can still use it.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Tools.Device

  @impl EMCP.Tool
  def name(), do: "grep_dmesg"

  @impl EMCP.Tool
  def description(),
    do: "Filter the connected Nerves device's `dmesg` output by a substring or regex pattern"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        pattern: %{
          type: :string,
          description: "Substring (or regex if `regex` is true) to match dmesg lines against"
        },
        regex: %{
          type: :boolean,
          description: "Treat pattern as an Elixir regex (default: false)"
        },
        tail: %{
          type: :integer,
          description: "Return only the last N matching lines"
        },
        timeout: %{
          type: :integer,
          description: "Timeout in milliseconds (default: 15000)"
        }
      },
      required: [:pattern]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    pattern = args["pattern"]
    regex? = args["regex"] || false
    tail = args["tail"]
    timeout = args["timeout"] || 15_000

    result =
      case request(DeviceProbe.mode(), pattern, regex?, tail) do
        {:eval_output, code} -> Device.eval_output(code, timeout)
        {:shell_eval_output, command} -> Device.shell_eval_output(command, timeout)
      end

    case result do
      {:ok, output} -> EMCP.Tool.response([%{"type" => "text", "text" => output}])
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end

  @doc """
  The `NervesMCP.Tools.Device` call a mode dispatches to, and the code for it.

  Both forms have to run on the far end, so this is the seam the tests use
  rather than a link.
  """
  @spec request(DeviceProbe.mode(), String.t(), boolean(), integer() | nil) ::
          {:eval_output | :shell_eval_output, String.t()}
  def request(:shell, pattern, regex?, tail),
    do: {:shell_eval_output, build_command(pattern, regex?, tail)}

  def request(_mode, pattern, regex?, tail),
    do: {:eval_output, build_code(pattern, regex?, tail)}

  # grep -E is the closest a shell gets to an Elixir regex, and -F pins a plain
  # substring so a `.` or `*` in the pattern stays literal.
  defp build_command(pattern, regex?, tail) do
    grep = if regex?, do: "grep -E --", else: "grep -F --"
    command = "dmesg | #{grep} #{shell_quote(pattern)}"

    if is_integer(tail), do: command <> " | tail -n #{tail}", else: command
  end

  defp shell_quote(string), do: "'" <> String.replace(string, "'", "'\\''") <> "'"

  defp build_code(pattern, regex?, tail) do
    tail_literal = if is_integer(tail), do: Integer.to_string(tail), else: "nil"

    """
    (fn ->
      pattern = #{inspect(pattern)}
      regex? = #{regex?}
      tail = #{tail_literal}

      matcher =
        if regex? do
          re = Regex.compile!(pattern)
          fn line -> Regex.match?(re, line) end
        else
          fn line -> String.contains?(line, pattern) end
        end

      output =
        try do
          :os.cmd(~c"dmesg") |> to_string()
        rescue
          e -> {:error, Exception.message(e)}
        end

      case output do
        {:error, msg} ->
          IO.puts("Error running dmesg: " <> msg)

        binary when is_binary(binary) ->
          lines =
            binary
            |> String.split("\n", trim: true)
            |> Enum.filter(matcher)

          lines = if tail, do: Enum.take(lines, -tail), else: lines
          Enum.each(lines, &IO.puts/1)
          length(lines)
      end
    end).()
    """
  end
end
