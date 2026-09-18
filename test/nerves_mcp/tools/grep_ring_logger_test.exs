# The harness IEx runs in this node, so the device-side code finds this module
# where a device finds the real one.
defmodule RingLogger do
  @moduledoc false

  def get(_index) do
    [
      %{
        level: :info,
        module: Boot,
        message: "starting up",
        timestamp: {{2026, 9, 17}, {15, 4, 5, 7}},
        metadata: []
      },
      %{
        level: :error,
        module: Modem,
        message: ["modem ", "went away"],
        timestamp: {{2026, 9, 17}, {15, 4, 6, 123}},
        metadata: []
      }
    ]
  end
end

defmodule NervesMCP.Tools.GrepRingLoggerTest do
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.GrepRingLogger

  @entry %{
    level: :info,
    module: SomeModule,
    message: "Bar started",
    timestamp: {{2026, 9, 17}, {15, 4, 5, 7}},
    metadata: [index: 1]
  }

  test "a RingLogger entry map formats as timestamp, level and message" do
    assert GrepRingLogger.format_entry(@entry) == "2026-09-17 15:04:05.007 [info] Bar started"
  end

  test "chardata messages are flattened" do
    entry = %{@entry | level: :warning, message: ["io", 32, "data"]}

    assert GrepRingLogger.format_entry(entry) == "2026-09-17 15:04:05.007 [warning] io data"
  end

  test "a message that is not chardata is inspected rather than raising" do
    entry = %{@entry | message: %{reason: :timeout}}

    assert GrepRingLogger.format_entry(entry) ==
             "2026-09-17 15:04:05.007 [info] %{reason: :timeout}"
  end

  # RingLogger before 0.8 handed out this shape.
  test "the older entry tuple still formats" do
    entry = {:error, {Logger, "old shape", {{2026, 9, 17}, {1, 2, 3, 4}}, []}}

    assert GrepRingLogger.format_entry(entry) == "2026-09-17 01:02:03.004 [error] old shape"
  end

  test "a timestamp without milliseconds formats" do
    entry = %{@entry | timestamp: {{2026, 9, 17}, {15, 4, 5}}}

    assert GrepRingLogger.format_entry(entry) == "2026-09-17 15:04:05 [info] Bar started"
  end

  test "anything else falls back to inspect" do
    assert GrepRingLogger.format_entry(:garbage) == ":garbage"
  end

  describe "over the harness" do
    setup do
      start_supervised!(NervesMCP.History)
      daemon = SSHDaemon.start()
      on_exit(fn -> SSHDaemon.stop(daemon) end)

      SSHDaemon.connect(daemon)
      start_supervised!(DeviceProbe)
      DeviceProbe.refresh()

      :ok
    end

    test "only the matching entries come back, formatted" do
      assert %{"content" => [%{"text" => text}]} =
               GrepRingLogger.call(nil, %{"pattern" => "modem"})

      assert text =~ "2026-09-17 15:04:06.123 [error] modem went away"
      refute text =~ "starting up"
    end
  end
end
