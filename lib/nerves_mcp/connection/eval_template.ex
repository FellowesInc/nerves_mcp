defmodule NervesMCP.Connection.EvalTemplate do
  @moduledoc """
  The wire protocol both transports use to run code in a device's IEx.

  One call is one expression. It prints `<marker>_START`, the result, then
  `<marker>_END`, and the transport feeds received bytes to a `Matcher` until it
  answers `{:done, result}`.

  User code travels as base64 broken across short lines. The remote line editor
  truncates a single line longer than about 4 KB, and the truncation reaches the
  compiler as `"aaa..." <> ...`, which fails with `undefined function .../0`.
  Short lines are not truncated, and base64 also keeps quoting and non-UTF8
  bytes out of the picture.
  """

  alias NervesMCP.Connection.EvalTemplate.Matcher

  # Well under the ~4 KB the remote line editor tolerates, and a multiple of 4 so
  # each line is whole base64 groups.
  @line_width 76

  @type style() :: :elixir | :shell

  @doc "A random marker to anchor one call's output on."
  @spec marker() :: String.t()
  def marker() do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16()
  end

  @doc """
  Wrap `code` so the device evaluates it and prints the inspected result.

  An exception is formatted into the reply rather than raised, so a failing
  evaluation is still a complete round trip.
  """
  @spec eval(String.t(), String.t()) :: String.t()
  def eval(code, marker) do
    """
    (fn ->
      result = try do
        {value, _binding} = Code.eval_string(#{payload(code)})
        {:ok, inspect(value, pretty: true, limit: :infinity)}
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end
      IO.puts("#{marker}_START")
      case result do
        {:ok, output} -> IO.puts(output)
        {:error, msg} -> IO.puts("ERROR: " <> msg)
      end
      IO.puts("#{marker}_END")
      :ok
    end).()
    """
  end

  @doc """
  Wrap `code` so the device prints what it wrote to stdout as well as its result.

  The group leader is swapped for a `StringIO` around the evaluation, so only the
  code's own output is captured and the markers still go to the real console.
  """
  @spec eval_output(String.t(), String.t()) :: String.t()
  def eval_output(code, marker) do
    """
    (fn ->
      {:ok, capture_pid} = StringIO.open("")
      old_gl = Process.group_leader()
      Process.group_leader(self(), capture_pid)

      {output, result} = try do
        {value, _binding} = Code.eval_string(#{payload(code)})
        Process.group_leader(self(), old_gl)
        {_, captured} = StringIO.contents(capture_pid)
        {captured, {:ok, inspect(value, pretty: true, limit: :infinity)}}
      rescue
        e ->
          Process.group_leader(self(), old_gl)
          {_, captured} = StringIO.contents(capture_pid)
          {captured, {:error, Exception.format(:error, e, __STACKTRACE__)}}
      catch
        kind, reason ->
          Process.group_leader(self(), old_gl)
          {_, captured} = StringIO.contents(capture_pid)
          {captured, {:error, Exception.format(kind, reason, __STACKTRACE__)}}
      end

      StringIO.close(capture_pid)

      IO.puts("#{marker}_START")
      IO.puts("OUTPUT:")
      IO.write(output)
      IO.puts("RESULT:")
      case result do
        {:ok, val} -> IO.puts(val)
        {:error, msg} -> IO.puts("ERROR: " <> msg)
      end
      IO.puts("#{marker}_END")
      :ok
    end).()
    """
  end

  @doc "Wrap a raw shell command. Used in degraded shell mode, where there is no IEx."
  @spec shell_eval(String.t(), String.t()) :: String.t()
  def shell_eval(command, marker) do
    "echo '#{marker}_START'\n#{command}\necho '#{marker}_END'\n"
  end

  @doc "Wrap a raw shell command so stdout, stderr and the exit code all come back."
  @spec shell_eval_output(String.t(), String.t()) :: String.t()
  def shell_eval_output(command, marker) do
    "echo '#{marker}_START'\n" <>
      "echo 'OUTPUT:'\n" <>
      "#{command} 2>&1\n" <>
      "__mcp_rc=$?\n" <>
      "echo 'RESULT:'\n" <>
      "echo \"Exit code: $__mcp_rc\"\n" <>
      "echo '#{marker}_END'\n"
  end

  @doc """
  The code the probe runs. Short enough to answer fast, specific enough that the
  reply identifies a Nerves device.
  """
  @spec probe_code() :: String.t()
  def probe_code() do
    ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|
  end

  @doc """
  Start collecting output for `marker`.

  `style` is `:elixir` for IEx output or `:shell` for a degraded shell. `:anchor`
  says which side of the printed marker line to match on, so the echoed source
  line is skipped. See `NervesMCP.Connection.EvalTemplate.Matcher`.
  """
  @spec matcher(String.t(), style(), keyword()) :: Matcher.t()
  defdelegate matcher(marker, style, opts \\ []), to: Matcher, as: :new

  # The user's code as an expression that reconstructs it on the device.
  defp payload(code) do
    lines = code |> Base.encode64() |> chunk_lines()

    ~s|Base.decode64!(~S"""\n#{lines}\n""", ignore: :whitespace)|
  end

  defp chunk_lines(base64) when byte_size(base64) <= @line_width, do: base64

  defp chunk_lines(<<line::binary-size(@line_width), rest::binary>>) do
    line <> "\n" <> chunk_lines(rest)
  end
end

defmodule NervesMCP.Connection.EvalTemplate.Matcher do
  @moduledoc """
  Picks one call's output out of a stream of device bytes.

  Bytes arrive in arbitrary chunks and a marker can straddle two of them, so the
  matcher keeps just enough of a tail to catch that, and scans only what is new
  on each chunk rather than the whole buffer.

  Anchoring skips the marker's own echo. `:trailing` matches the CRLF the device
  prints after the marker, `:leading` the newline printed before it. A shell has
  no reliable echo to skip, so `:shell` matches the bare marker and tidies the
  newlines around it.
  """

  @enforce_keys [:start_marker, :end_marker, :style]
  defstruct [
    :start_marker,
    :end_marker,
    :style,
    state: :seeking,
    acc: "",
    scanned: 0,
    output?: false
  ]

  @type t() :: %__MODULE__{}

  @doc "Build a matcher for `marker`. See `NervesMCP.Connection.EvalTemplate.matcher/3`."
  @spec new(String.t(), NervesMCP.Connection.EvalTemplate.style(), keyword()) :: t()
  def new(marker, style, opts \\ []) do
    {start_marker, end_marker} = markers(marker, style, Keyword.get(opts, :anchor, :trailing))

    %__MODULE__{start_marker: start_marker, end_marker: end_marker, style: style}
  end

  defp markers(marker, :shell, _anchor), do: {"#{marker}_START", "#{marker}_END"}
  defp markers(marker, :elixir, :leading), do: {"\n#{marker}_START\r", "\n#{marker}_END\r"}
  defp markers(marker, :elixir, :trailing), do: {"#{marker}_START\r\n", "#{marker}_END\r\n"}

  @doc """
  Feed a chunk of device output in.

  Answers `{:done, result}` once the end marker has arrived, `{:cont, matcher}`
  otherwise.
  """
  @spec feed(t(), binary()) :: {:done, String.t()} | {:cont, t()}
  def feed(matcher, data) do
    matcher = %{matcher | output?: matcher.output? or String.trim(data) != ""}

    case matcher.state do
      :seeking -> seek_start(matcher, data)
      :collecting -> collect(matcher, data)
    end
  end

  @doc "Whether anything but whitespace has arrived since the call went out."
  @spec output?(t()) :: boolean()
  def output?(matcher), do: matcher.output?

  # Bytes before the start marker are not part of the result, so only a partial
  # marker is worth keeping.
  defp seek_start(matcher, data) do
    acc = matcher.acc <> data

    case :binary.match(acc, matcher.start_marker) do
      {pos, len} ->
        rest = binary_part(acc, pos + len, byte_size(acc) - pos - len)
        collect(%{matcher | state: :collecting, acc: "", scanned: 0}, rest)

      :nomatch ->
        keep = min(byte_size(acc), byte_size(matcher.start_marker) - 1)
        {:cont, %{matcher | acc: binary_part(acc, byte_size(acc) - keep, keep)}}
    end
  end

  defp collect(matcher, data) do
    acc = matcher.acc <> data
    from = max(matcher.scanned - (byte_size(matcher.end_marker) - 1), 0)

    case :binary.match(acc, matcher.end_marker, scope: {from, byte_size(acc) - from}) do
      {pos, _len} ->
        {:done, finish(matcher.style, binary_part(acc, 0, pos))}

      :nomatch ->
        {:cont, %{matcher | acc: acc, scanned: byte_size(acc)}}
    end
  end

  defp finish(:elixir, result), do: result

  defp finish(:shell, result) do
    result
    |> String.replace_leading("\r\n", "")
    |> String.replace_leading("\r", "")
    |> String.replace_leading("\n", "")
    |> String.trim_trailing()
  end
end
