defmodule NervesMCP.History do
  @moduledoc """
  Stores recent device output in a circular buffer.

  Everything the session prints lands here, including output from processes
  spawned on the device, which never reaches the caller of `device_eval`.
  `since/1` hands that back a chunk at a time with the eval protocol filtered
  out (see `NervesMCP.Tools.DeviceOutput`).

  ## Known limitation

  A line printed while an eval's result is crossing the link is lost. The
  result is fenced by the wrapper's markers and dropped as protocol, and a line
  another process wrote inside that fence is byte for byte indistinguishable
  from a line of the result: the session is one stream with no per-writer tag.
  The fence spans only the few writes it takes to print the result, so the
  window is short.
  """

  use Agent

  @default_size 10_000

  # The eval wrapper's markers, as Connection.SSH generates them.
  @marker ~r/\b[0-9A-F]{16}_(?:START|END)\b/
  @marker_start ~r/^([0-9A-F]{16})_START$/
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]/
  @newline ~r/\r\n|\r|\n/
  # A device prompt carries the node name and the counter: `iex(node@host)18>`.
  @prompt ~r/^(?:iex|\.\.\.)(?:\([^)]*\))?\d*>\s?/
  @wrapper_end "end).()"
  @wrapper_start "(fn ->"
  @initial_state %{kept: [], fencing: nil, echoing: false, returning: nil}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    size = Keyword.get(opts, :size, @default_size)
    Agent.start_link(fn -> CircularBuffer.new(size) end, name: __MODULE__)
  end

  @spec push(binary()) :: :ok
  def push(data) when is_binary(data) do
    Agent.update(__MODULE__, fn buffer ->
      CircularBuffer.insert(buffer, {System.monotonic_time(), data})
    end)
  end

  @spec get() :: String.t()
  def get() do
    Agent.get(__MODULE__, fn buffer ->
      buffer
      |> CircularBuffer.to_list()
      |> Enum.map_join(fn {_ts, data} -> data end)
    end)
  end

  @doc """
  Device output buffered after `cursor`, plus the cursor to pass next time.

  `nil` reads everything still in the buffer. The cursor is a monotonic
  timestamp, so it is only meaningful to this server process.
  """
  @spec since(integer() | nil) :: {String.t(), integer()}
  def since(cursor \\ nil) do
    entries = Agent.get(__MODULE__, &CircularBuffer.to_list/1)
    {fresh, stale} = Enum.split_with(entries, &fresher?(&1, cursor))

    {device_output(join(stale), join(fresh)), next_cursor(fresh, entries, cursor)}
  end

  @spec clear() :: :ok
  def clear() do
    Agent.update(__MODULE__, fn buffer ->
      CircularBuffer.new(buffer.max_size)
    end)
  end

  defp join(entries), do: Enum.map_join(entries, fn {_ts, data} -> data end)

  defp fresher?(_entry, nil), do: true
  defp fresher?({ts, _data}, cursor), do: ts > cursor

  defp next_cursor([_ | _] = fresh, _entries, _cursor), do: fresh |> List.last() |> elem(0)
  defp next_cursor([], _entries, cursor) when is_integer(cursor), do: cursor
  defp next_cursor([], [_ | _] = entries, nil), do: entries |> List.last() |> elem(0)
  defp next_cursor([], [], nil), do: System.monotonic_time()

  # What the device printed, with the eval protocol taken out: the PTY echo of
  # the wrapper, the markers, the result they fence, the IEx prompts, and the
  # wrapper's own return echoed after the closing marker. What is left is the
  # output a caller cannot get any other way, such as a process printing after
  # its eval returned.
  #
  # The whole buffer is filtered, not just the part after the cursor, and the
  # stale lines are thrown away at the end. The protocol spans several lines, so
  # a cursor landing inside one would otherwise start the filter mid-sequence
  # and leak the rest of it: a fenced result whose START it never saw, or the
  # wrapper's trailing `:ok`.
  defp device_output(stale, fresh) do
    stale = clean(stale)
    # A line straddling the cursor counts as fresh.
    skip = stale |> split_lines() |> length() |> Kernel.-(1)

    (stale <> clean(fresh))
    |> split_lines()
    |> Enum.with_index()
    |> Enum.reduce(@initial_state, fn {raw, index}, state ->
      take_line(raw, index >= skip, state)
    end)
    |> Map.fetch!(:kept)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp clean(raw) do
    raw
    |> String.replace(@ansi, "")
    |> String.replace(["\b", "\a"], "")
  end

  defp split_lines(text), do: String.split(text, @newline)

  defp take_line(raw, fresh?, state) do
    line = raw |> String.replace(@prompt, "") |> String.trim_trailing()
    take_line(line, String.trim(line), fresh?, state)
  end

  # Between the markers: the fenced result, which the caller already got. The
  # wrapper's return value follows the closing marker.
  defp take_line(_line, trimmed, _fresh?, %{fencing: marker} = state) when is_binary(marker) do
    if trimmed == marker <> "_END", do: %{state | fencing: nil, returning: :ok}, else: state
  end

  # IEx echoes the wrapper's `:ok` after the closing marker, then one `nil` per
  # blank line the connection sent after the code. Only in that position: `:ok`
  # and `nil` anywhere else are what a process on the device printed, so the
  # first line that is neither ends the run and is kept.
  defp take_line(line, trimmed, fresh?, %{returning: expected} = state)
       when not is_nil(expected) do
    case {expected, trimmed} do
      {_expected, ""} -> state
      {:ok, ":ok"} -> %{state | returning: :nils}
      {:nils, "nil"} -> state
      _other -> take_line(line, trimmed, fresh?, %{state | returning: nil})
    end
  end

  # Inside the wrapper's echo, which ends at its own `end).()` or at the START
  # marker the device prints next.
  defp take_line(_line, trimmed, _fresh?, %{echoing: true} = state) do
    case Regex.run(@marker_start, trimmed) do
      [_line, marker] -> %{state | fencing: marker, echoing: false}
      nil -> %{state | echoing: trimmed != @wrapper_end}
    end
  end

  defp take_line(line, trimmed, fresh?, state) do
    cond do
      match = Regex.run(@marker_start, trimmed) -> %{state | fencing: Enum.at(match, 1)}
      Regex.match?(@marker, trimmed) -> state
      trimmed == "" -> state
      trimmed == @wrapper_start -> %{state | echoing: true}
      trimmed == @wrapper_end -> %{state | kept: drop_echo(state.kept)}
      fresh? -> %{state | kept: [line | state.kept]}
      true -> state
    end
  end

  # Fallback for an echo whose `(fn ->` was cut by a redraw: drop backwards from
  # `end).()` while the lines are indented, which the wrapper body always is.
  defp drop_echo([line | rest]) do
    cond do
      String.trim(line) == @wrapper_start -> rest
      line != String.trim_leading(line) -> drop_echo(rest)
      true -> [line | rest]
    end
  end

  defp drop_echo([]), do: []
end
