defmodule NervesMCP.History do
  @moduledoc """
  Stores recent device output in a circular buffer.

  Everything the session prints lands here, including output from processes
  spawned on the device, which never reaches the caller of `device_eval`.
  `since/1` hands that back a chunk at a time with the eval protocol filtered
  out (see `NervesMCP.Tools.DeviceOutput`).
  """

  use Agent

  @default_size 10_000

  # The eval wrapper's markers, as Connection.SSH generates them.
  @marker ~r/\b[0-9A-F]{16}_(?:START|END)\b/
  @marker_start ~r/^([0-9A-F]{16})_START$/
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]/
  @prompt ~r/^(?:iex|\.\.\.)(?:\([^)]*\))?>\s?/
  @wrapper_end "end).()"
  @wrapper_start "(fn ->"

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
    fresh = Enum.filter(entries, &fresher?(&1, cursor))

    {fresh |> Enum.map_join(fn {_ts, data} -> data end) |> device_output(),
     next_cursor(fresh, entries, cursor)}
  end

  @spec clear() :: :ok
  def clear() do
    Agent.update(__MODULE__, fn buffer ->
      CircularBuffer.new(buffer.max_size)
    end)
  end

  defp fresher?(_entry, nil), do: true
  defp fresher?({ts, _data}, cursor), do: ts > cursor

  defp next_cursor([_ | _] = fresh, _entries, _cursor), do: fresh |> List.last() |> elem(0)
  defp next_cursor([], _entries, cursor) when is_integer(cursor), do: cursor
  defp next_cursor([], [_ | _] = entries, nil), do: entries |> List.last() |> elem(0)
  defp next_cursor([], [], nil), do: System.monotonic_time()

  # What the device printed, with the eval protocol taken out: the PTY echo of
  # the wrapper, the markers, the result they fence, and the IEx prompts. A line
  # that is only `:ok` or `nil` goes too, since that is IEx echoing the wrapper's
  # return and the blank line sent after it. What is left is the output a caller
  # cannot get any other way, such as a process printing after its eval returned.
  defp device_output(raw) do
    raw
    |> String.replace(@ansi, "")
    |> String.replace(["\b", "\a"], "")
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce(%{kept: [], fencing: nil, echoing: false}, &take_line/2)
    |> Map.fetch!(:kept)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp take_line(line, state) do
    line = line |> String.replace(@prompt, "") |> String.trim_trailing()
    trimmed = String.trim(line)

    cond do
      state.fencing ->
        if trimmed == state.fencing <> "_END", do: %{state | fencing: nil}, else: state

      match = Regex.run(@marker_start, trimmed) ->
        %{state | fencing: Enum.at(match, 1), echoing: false}

      state.echoing ->
        %{state | echoing: trimmed != @wrapper_end}

      trimmed == @wrapper_start ->
        %{state | echoing: true}

      Regex.match?(@marker, trimmed) ->
        state

      trimmed in ["", ":ok", "nil"] ->
        state

      trimmed == @wrapper_end ->
        %{state | kept: drop_echo(state.kept)}

      true ->
        %{state | kept: [line | state.kept]}
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
