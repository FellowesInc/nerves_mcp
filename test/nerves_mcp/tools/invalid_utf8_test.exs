defmodule NervesMCP.Tools.InvalidUTF8Test do
  # A serial console prints bytes that aren't UTF-8 around a reset or at the wrong
  # baud rate. The tools answer in JSON, so each of these used to fail the call
  # with `{:invalid_byte, 207}` from `JSON.encode!/1`.
  use ExUnit.Case, async: false

  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices
  alias NervesMCP.History
  alias NervesMCP.Test.RawShell
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.DeviceEval
  alias NervesMCP.Tools.DeviceEvalOutput
  alias NervesMCP.Tools.DeviceOutput
  alias NervesMCP.Tools.GrepDmesg

  @device "board1"

  setup do
    daemon = SSHDaemon.start({:ssh_cli, {RawShell, [<<0xCF, "ok\r\n">>]}})
    previous = Application.get_env(:nerves_mcp, :devices)

    devices = [
      {@device,
       type: :ssh, host: "127.0.0.1", port: daemon.port, user: System.get_env("USER", "nobody")}
    ]

    Application.put_env(:nerves_mcp, :devices, devices)
    start_supervised!({Devices, devices})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_mcp, :devices, previous),
        else: Application.delete_env(:nerves_mcp, :devices)

      SSHDaemon.stop(daemon)
    end)

    assert eventually(fn -> elem(DeviceProbe.refresh(@device), 0) == :elixir end, 40)
    :ok
  end

  test "device_output replaces an invalid byte and the response encodes" do
    {_caught_up, cursor} = History.since(@device, nil)
    History.push(@device, <<0xCF, "ok\n">>)

    response = DeviceOutput.call(nil, %{"device" => @device, "cursor" => cursor})

    assert %{"content" => [%{"text" => "�ok\n\ncursor: " <> _cursor}]} = response
    assert is_binary(JSON.encode!(response))
  end

  # A read can end mid-character, so replacing per chunk would turn a valid
  # character into two replacements.
  test "device_output keeps a character split across two chunks" do
    <<first::binary-size(1), second::binary>> = "é"
    {_caught_up, cursor} = History.since(@device, nil)
    History.push(@device, first)
    History.push(@device, second <> "\n")

    assert %{"content" => [%{"text" => "é\n\ncursor: " <> _cursor}]} =
             DeviceOutput.call(nil, %{"device" => @device, "cursor" => cursor})
  end

  test "the eval tools replace an invalid byte and their responses encode" do
    calls = [
      {DeviceEval, %{"code" => "1 + 1"}},
      {DeviceEvalOutput, %{"code" => "1 + 1"}},
      {GrepDmesg, %{"pattern" => "usb"}}
    ]

    for {tool, args} <- calls do
      response = tool.call(nil, Map.put(args, "device", @device))

      assert %{"content" => [%{"text" => "�ok\r\n"}]} = response, inspect(tool)
      assert is_binary(JSON.encode!(response))
    end
  end

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(250) && eventually(fun, tries - 1)
    end
  end
end
