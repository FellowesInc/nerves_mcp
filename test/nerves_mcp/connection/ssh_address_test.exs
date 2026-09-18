defmodule NervesMCP.Connection.SSHAddressTest do
  # The harness daemon runs in this VM, so the "device" reports this machine's
  # hostname. A name whose first label is that hostname but which can't resolve
  # stands in for a device whose mDNS name has gone quiet, and 127.0.0.1 on the
  # harness port is its address.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NervesMCP.Connection.AddressCache
  alias NervesMCP.Connection.SSH
  alias NervesMCP.DeviceProbe
  alias NervesMCP.Test.SSHDaemon
  alias NervesMCP.Tools.Device
  alias NervesMCP.Tools.DeviceStatus
  alias NervesMCP.Tools.IsDeviceUp
  alias NervesMCP.Tools.SetDeviceAddress

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  setup %{tmp_dir: dir} do
    start_supervised!(NervesMCP.History)
    daemon = SSHDaemon.start()
    on_exit(fn -> SSHDaemon.stop(daemon) end)

    restore_env_on_exit(:connection)
    restore_env_on_exit(:address_cache_dir)
    Application.put_env(:nerves_mcp, :address_cache_dir, dir)

    %{daemon: daemon, cache: AddressCache.path(dir), hostname: local_hostname()}
  end

  test "an answer on the name caches the address it resolves to, on disk", ctx do
    start_ssh("localhost", ctx.daemon)
    assert evaluates?()

    assert eventually(fn -> AddressCache.lookup(ctx.cache, "localhost") == "127.0.0.1" end)

    stop_supervised!(SSH)
    assert {:ok, [{"localhost", "127.0.0.1"}]} = :file.consult(ctx.cache)
    assert AddressCache.lookup(ctx.cache, "localhost") == "127.0.0.1"
  end

  test "a name that won't resolve falls back to the cached address and checks it", ctx do
    AddressCache.put(ctx.cache, ctx.hostname, "127.0.0.1")

    log =
      capture_log(fn ->
        start_ssh("#{ctx.hostname}.invalid", ctx.daemon)
        assert evaluates?()
      end)

    assert log =~ "Trying address 127.0.0.1 for #{ctx.hostname}.invalid"
    assert log =~ "Verified 127.0.0.1 is #{ctx.hostname}.invalid"
    assert %{target: "127.0.0.1", address: "127.0.0.1", reason: nil} = SSH.status()
  end

  test "a cached address that answers as another device is dropped and never evaluates", ctx do
    AddressCache.put(ctx.cache, "nerves-1234", "127.0.0.1")
    start_ssh("nerves-1234.invalid", ctx.daemon)
    start_supervised!(DeviceProbe)

    assert eventually(fn ->
             refute match?({:ok, _}, SSH.eval("1 + 1", 500))
             SSH.status().reason != nil and String.contains?(SSH.status().reason, "answered")
           end)

    assert AddressCache.lookup(ctx.cache, "nerves-1234") == nil

    reason =
      "127.0.0.1 answered as #{ctx.hostname}, not nerves-1234. DHCP has likely given it to " <>
        "another device, so it is no longer used. Ask the user for the device's IP " <>
        "address, then call set_device_address."

    assert SSH.status().reason == reason

    assert {:down, _detail} = DeviceProbe.refresh()
    assert Device.ensure_up() == {:error, "Device is down (mode: down). " <> reason}
  end

  # The shell prints a line and then swallows everything, so the address answers
  # but the hostname check never does.
  test "an address runs no evals before it checks out, and one that never does is dropped",
       ctx do
    daemon =
      SSHDaemon.start(fn _user, _peer ->
        spawn(fn ->
          IO.puts("not iex")
          Process.sleep(:infinity)
        end)
      end)

    on_exit(fn -> SSHDaemon.stop(daemon) end)

    AddressCache.put(ctx.cache, ctx.hostname, "127.0.0.1")
    host = "#{ctx.hostname}.invalid"

    reason =
      "#{host} isn't answering and neither is 127.0.0.1. If the device should be up by " <>
        "now, ask the user for its IP address, then call set_device_address."

    log =
      capture_log(fn ->
        start_ssh(host, daemon)

        checking = {:error, "Device not connected (checking 127.0.0.1 is #{host})"}
        assert eventually(fn -> SSH.eval("1 + 1", 500) == checking end)
        assert eventually(fn -> SSH.status().reason == reason end)
      end)

    assert log =~ "127.0.0.1 never reported its hostname, dropping it"
  end

  test "no cached address and a name that won't resolve asks for the address", ctx do
    start_ssh("nerves-1234.invalid", ctx.daemon)
    start_supervised!(DeviceProbe)

    reason =
      "nerves-1234.invalid isn't answering and no address is known for this device. " <>
        "Ask the user for the device's IP address, then call set_device_address."

    assert eventually(fn -> SSH.status().reason == reason end)

    assert {:down, _detail} = DeviceProbe.refresh()
    assert Device.ensure_up() == {:error, "Device is down (mode: down). " <> reason}

    assert %{"content" => [%{"text" => text}], "isError" => true} =
             IsDeviceUp.call(nil, %{"timeout" => 1_000})

    assert text == "Timed out waiting for device to come up. " <> reason

    assert %{"content" => [%{"text" => status}]} = DeviceStatus.call(nil, %{})
    assert status =~ "SSH target: nerves-1234.invalid\nReason: #{reason}"
  end

  test "set_device_address connects to an address that checks out and caches it", ctx do
    start_ssh("#{ctx.hostname}.invalid", ctx.daemon)
    assert eventually(fn -> SSH.status().reason != nil end)

    assert %{"content" => [%{"text" => text}]} =
             SetDeviceAddress.call(nil, %{"address" => "127.0.0.1"})

    assert text == "127.0.0.1 answered as #{ctx.hostname}. Connected, and cached for next time."
    assert {:ok, "2" <> _} = SSH.eval("1 + 1", 5_000)
    assert AddressCache.lookup(ctx.cache, ctx.hostname) == "127.0.0.1"
    assert SSH.status().reason == nil
  end

  test "set_device_address rejects an address that answers as another device", ctx do
    start_ssh("nerves-1234.invalid", ctx.daemon)

    assert %{"content" => [%{"text" => text}], "isError" => true} =
             SetDeviceAddress.call(nil, %{"address" => "127.0.0.1"})

    assert text =~ "127.0.0.1 answered as #{ctx.hostname}, not nerves-1234."
    assert AddressCache.lookup(ctx.cache, "nerves-1234") == nil
    refute match?({:ok, _}, SSH.eval("1 + 1", 500))

    assert %{"content" => [%{"text" => "\"nerves-1234\" is not an IP address"}]} =
             SetDeviceAddress.call(nil, %{"address" => "nerves-1234"})
  end

  test "an IP host learns nothing and takes no address", ctx do
    start_ssh("127.0.0.1", ctx.daemon)
    assert evaluates?()

    # Long enough for a learn task to have written, had one started.
    Process.sleep(500)
    refute File.exists?(ctx.cache)

    assert %{"content" => [%{"text" => text}], "isError" => true} =
             SetDeviceAddress.call(nil, %{"address" => "127.0.0.1"})

    assert text =~ "127.0.0.1 is an address already"
    assert SSH.status().reason == nil
  end

  defp start_ssh(host, daemon) do
    Application.put_env(:nerves_mcp, :connection,
      type: :ssh,
      host: host,
      port: daemon.port,
      user: System.get_env("USER", "nobody")
    )

    start_supervised!(SSH)
  end

  defp evaluates?() do
    eventually(fn -> match?({:ok, "2" <> _}, SSH.eval("1 + 1", 1_000)) end)
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(250)
        eventually(fun, tries - 1)
    end
  end

  defp local_hostname() do
    {:ok, hostname} = :inet.gethostname()
    hostname |> to_string() |> String.split(".") |> hd() |> String.downcase()
  end

  defp restore_env_on_exit(key) do
    previous = Application.fetch_env(:nerves_mcp, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nerves_mcp, key, value)
        :error -> Application.delete_env(:nerves_mcp, key)
      end
    end)
  end
end
