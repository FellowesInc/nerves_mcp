defmodule NervesMCP.Connection.AddressCache do
  @moduledoc """
  The last address each device answered on, keyed by its hostname, on disk.

  An mDNS name can stay unresolvable for minutes after a device reboots while
  its IP already answers. The address learned while the name worked is what the
  SSH connection falls back on. DHCP can hand that address to another device, so
  the connection checks the hostname before trusting it.

  The file is one `{hostname, address}` term per line, read with
  `:file.consult/1`. A missing or unreadable file is an empty cache.

  ### API

    * `path/1` — the cache file in a directory
    * `lookup/2` — the address cached for a hostname
    * `put/3` — cache an address
    * `delete/3` — drop an address that no longer belongs to the hostname
    * `learn/3` — resolve a name and cache what it resolves to
  """

  require Logger

  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, "addresses.term")

  @spec lookup(Path.t(), String.t()) :: String.t() | nil
  def lookup(path, hostname), do: path |> read() |> Map.get(hostname)

  @spec put(Path.t(), String.t(), String.t()) :: :ok
  def put(path, hostname, address) do
    path |> read() |> Map.put(hostname, address) |> write(path)
  end

  @doc "Drop `hostname`'s entry, but only while it still points at `address`."
  @spec delete(Path.t(), String.t(), String.t()) :: :ok
  def delete(path, hostname, address) do
    case read(path) do
      %{^hostname => ^address} = entries -> entries |> Map.delete(hostname) |> write(path)
      _other_or_none -> :ok
    end
  end

  @doc """
  Resolve `name` on this machine and cache the IPv4 address under `hostname`.

  Only called once a connection to `name` has answered, so the address is known
  to reach the device.
  """
  @spec learn(Path.t(), String.t(), String.t()) :: :ok
  def learn(path, hostname, name) do
    with {:ok, ip} <- :inet.getaddr(String.to_charlist(name), :inet),
         address = to_string(:inet.ntoa(ip)),
         false <- lookup(path, hostname) == address do
      Logger.info("Learned address #{address} for #{name}")
      put(path, hostname, address)
    end

    :ok
  end

  defp read(path) do
    case :file.consult(path) do
      {:ok, terms} ->
        for {hostname, address} when is_binary(hostname) and is_binary(address) <- terms,
            into: %{},
            do: {hostname, address}

      {:error, _missing_or_corrupt} ->
        %{}
    end
  end

  # Written to a temp file and renamed over the old one, so a reader never sees
  # half a file.
  defp write(entries, path) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    contents = for entry <- entries, do: :io_lib.format("~tp.~n", [entry])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not write the address cache #{path}: #{inspect(reason)}")
    end
  end
end
