defmodule NervesMCP.Connection.AddressCacheTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Connection.AddressCache

  @moduletag :tmp_dir

  # Each device's connection learns into the same file, and they all answer at about the same
  # time after a restart.
  test "concurrent puts for different devices all land", %{tmp_dir: dir} do
    path = AddressCache.path(dir)

    1..30
    |> Enum.map(&Task.async(fn -> AddressCache.put(path, "nerves-#{&1}", "192.0.2.#{&1}") end))
    |> Task.await_many()

    for n <- 1..30, do: assert(AddressCache.lookup(path, "nerves-#{n}") == "192.0.2.#{n}")
  end

  test "a missing file is an empty cache", %{tmp_dir: dir} do
    assert AddressCache.lookup(AddressCache.path(dir), "nerves-1234") == nil
  end

  test "a corrupt file is an empty cache, and the next write replaces it", %{tmp_dir: dir} do
    path = AddressCache.path(dir)
    File.write!(path, "{<<\"nerves-1234\">>, <<\"192.0.2.10\">>")

    assert AddressCache.lookup(path, "nerves-1234") == nil

    assert :ok = AddressCache.put(path, "nerves-1234", "192.0.2.11")
    assert AddressCache.lookup(path, "nerves-1234") == "192.0.2.11"
  end

  test "an entry of the wrong shape is skipped", %{tmp_dir: dir} do
    path = AddressCache.path(dir)
    File.write!(path, "not_an_entry.\n{<<\"nerves-1234\">>, <<\"192.0.2.10\">>}.\n")

    assert AddressCache.lookup(path, "nerves-1234") == "192.0.2.10"
  end

  test "delete only drops an entry that still points at the address", %{tmp_dir: dir} do
    path = AddressCache.path(dir)
    AddressCache.put(path, "nerves-1234", "192.0.2.10")

    AddressCache.delete(path, "nerves-1234", "192.0.2.99")
    assert AddressCache.lookup(path, "nerves-1234") == "192.0.2.10"

    AddressCache.delete(path, "nerves-1234", "192.0.2.10")
    assert AddressCache.lookup(path, "nerves-1234") == nil
  end
end
