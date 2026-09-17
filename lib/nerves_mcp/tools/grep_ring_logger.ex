defmodule NervesMCP.Tools.GrepRingLogger do
  @moduledoc """
  Grep the device's RingLogger buffer.

  Fetches log entries from `RingLogger.get/1` on the connected device, formats
  each one as `timestamp [level] message`, and returns the lines matching the
  given pattern. Optionally limits the output to the last N matches.

  The formatting and the filtering both run on the device, so only the matches
  cross the link.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.Tools.Device

  # Runs on the device, so it is source rather than a function: RingLogger 0.8+
  # returns entry maps, and the older {level, {logger, message, timestamp,
  # metadata}} tuple is kept as a fallback. Anything else is inspected, which is
  # what every entry used to fall through to.
  @entry_formatter """
  (fn ->
     pad = fn number, width ->
       number |> Integer.to_string() |> String.pad_leading(width, "0")
     end

     stamp = fn
       {{year, month, day}, {hour, minute, second, millisecond}} ->
         pad.(year, 4) <> "-" <> pad.(month, 2) <> "-" <> pad.(day, 2) <> " " <>
           pad.(hour, 2) <> ":" <> pad.(minute, 2) <> ":" <> pad.(second, 2) <> "." <>
           pad.(millisecond, 3)

       {{year, month, day}, {hour, minute, second}} ->
         pad.(year, 4) <> "-" <> pad.(month, 2) <> "-" <> pad.(day, 2) <> " " <>
           pad.(hour, 2) <> ":" <> pad.(minute, 2) <> ":" <> pad.(second, 2)

       other ->
         inspect(other)
     end

     text = fn message ->
       try do
         IO.iodata_to_binary(message)
       rescue
         _ -> inspect(message)
       end
     end

     line = fn level, message, timestamp ->
       stamp.(timestamp) <> " [" <> to_string(level) <> "] " <> text.(message)
     end

     fn
       %{level: level, message: message, timestamp: timestamp} ->
         line.(level, message, timestamp)

       {level, {_logger, message, timestamp, _metadata}} ->
         line.(level, message, timestamp)

       other ->
         inspect(other)
     end
   end).()\
  """

  @impl EMCP.Tool
  def name(), do: "grep_ring_logger"

  @impl EMCP.Tool
  def description(),
    do: "Filter the connected Nerves device's RingLogger buffer by a substring or regex pattern"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        pattern: %{
          type: :string,
          description: "Substring (or regex if `regex` is true) to match log lines against"
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

    code = build_code(pattern, regex?, tail)

    case Device.eval_output(code, timeout) do
      {:ok, output} -> EMCP.Tool.response([%{"type" => "text", "text" => output}])
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end

  @doc """
  Format one RingLogger entry the way the device-side code does.

  The formatter has to run on the device, so it lives as source in
  `@entry_formatter` and this evaluates that same source. The tests exercise it
  here rather than over a link.
  """
  @spec format_entry(term()) :: String.t()
  def format_entry(entry) do
    {formatter, _binding} = Code.eval_string(@entry_formatter)
    formatter.(entry)
  end

  defp build_code(pattern, regex?, tail) do
    tail_literal = if is_integer(tail), do: Integer.to_string(tail), else: "nil"

    """
    (fn ->
      format = #{@entry_formatter}
      pattern = #{inspect(pattern)}
      regex? = #{regex?}
      tail = #{tail_literal}

      # What a pattern matches against. The application and module are in here
      # because grepping for an app name is the common case, and they cost
      # nothing next to formatting.
      match_text = fn entry ->
        {message, module, metadata} =
          case entry do
            %{message: message, module: module, metadata: metadata} ->
              {message, module, metadata}

            {_level, {_logger, message, _timestamp, metadata}} ->
              {message, nil, metadata}

            other ->
              {inspect(other), nil, []}
          end

        text =
          try do
            IO.iodata_to_binary(message)
          rescue
            _ -> inspect(message)
          end

        application =
          cond do
            is_list(metadata) -> Keyword.get(metadata, :application)
            is_map(metadata) -> Map.get(metadata, :application)
            true -> nil
          end

        text <> " " <> inspect(module) <> " " <> inspect(application)
      end

      matcher =
        if regex? do
          re = Regex.compile!(pattern)
          fn line -> Regex.match?(re, line) end
        else
          fn line -> String.contains?(line, pattern) end
        end

      entries =
        try do
          RingLogger.get(0)
        rescue
          UndefinedFunctionError -> {:error, :ring_logger_unavailable}
          e -> {:error, Exception.message(e)}
        end

      case entries do
        {:error, :ring_logger_unavailable} ->
          IO.puts("RingLogger is not available on this device")

        {:error, msg} ->
          IO.puts("Error fetching RingLogger entries: " <> msg)

        list when is_list(list) ->
          matches = Enum.filter(list, fn entry -> matcher.(match_text.(entry)) end)
          matches = if tail, do: Enum.take(matches, -tail), else: matches
          lines = Enum.map(matches, format)
          Enum.each(lines, &IO.puts/1)
          length(lines)
      end
    end).()
    """
  end
end
