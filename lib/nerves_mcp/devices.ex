defmodule NervesMCP.Devices do
  @moduledoc """
  The configured devices, and the supervisor that runs a `NervesMCP.Device` for
  each of them.

  Devices are named, and a tool call says which one it is for with its `device`
  argument. With only one device configured the argument can be left out. Each
  device's processes register in `NervesMCP.Registry` under `{name, role}`, so
  any of them finds its siblings from the device name alone.

  Configured with `:devices`, a list of `{name, connection}`:

      config :nerves_mcp, :devices, [
        {"board1", type: :ssh, host: "192.0.2.10", user: "root", port: 22},
        {"board2", type: :ssh, host: "192.0.2.11", user: "root", port: 22}
      ]

  A single `:connection` still works and runs as the device `"default"`.
  """

  use Supervisor

  alias NervesMCP.Connection.SSH
  alias NervesMCP.Connection.UART

  @registry NervesMCP.Registry
  @default "default"

  @type name() :: String.t()
  @type device() :: {name(), keyword()}

  @spec start_link([device()]) :: Supervisor.on_start()
  def start_link(devices) do
    Supervisor.start_link(__MODULE__, devices, name: __MODULE__)
  end

  @impl true
  def init(devices) do
    devices
    |> Enum.map(fn {name, connection} ->
      Supervisor.child_spec({NervesMCP.Device, name: name, connection: connection},
        id: {NervesMCP.Device, name}
      )
    end)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @doc "The name a single `:connection` runs as."
  @spec default() :: name()
  def default(), do: @default

  @doc "The configured devices: `:devices`, or `:connection` as the device `\"default\"`."
  @spec configured() :: [device()]
  def configured() do
    case Application.get_env(:nerves_mcp, :devices) do
      [_ | _] = devices -> devices
      _none -> single(Application.get_env(:nerves_mcp, :connection, []))
    end
  end

  defp single(connection) do
    if Keyword.has_key?(connection, :type), do: [{@default, connection}], else: []
  end

  @spec names() :: [name()]
  def names(), do: Enum.map(configured(), &elem(&1, 0))

  @doc "A configured device's connection settings, or `[]` when there is no such device."
  @spec connection(name()) :: keyword()
  def connection(name) do
    configured() |> List.keyfind(name, 0, {name, []}) |> elem(1)
  end

  @doc "The connection module that drives a device."
  @spec module(name() | keyword()) :: {:ok, module()} | {:error, String.t()}
  def module(name) when is_binary(name), do: name |> connection() |> module()

  def module(connection) when is_list(connection) do
    case Keyword.get(connection, :type) do
      :uart -> {:ok, UART}
      :ssh -> {:ok, SSH}
      other -> {:error, "Unknown connection type: #{inspect(other)}"}
    end
  end

  @doc "A device's connection as one line, e.g. `ssh root@nerves.local:22`."
  @spec describe(keyword()) :: String.t()
  def describe(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart ->
        "serial #{Keyword.fetch!(connection, :port)} @ #{Keyword.get(connection, :speed, 115_200)}"

      :ssh ->
        "ssh #{Keyword.get(connection, :user, "root")}@#{Keyword.fetch!(connection, :host)}:" <>
          "#{Keyword.get(connection, :port, 22)}"
    end
  end

  @doc "Where a device's process for `role` is registered."
  @spec via(name(), module()) :: GenServer.name()
  def via(name, role), do: {:via, Registry, {@registry, {name, role}}}

  @doc """
  The device a tool call is for. `nil` means the only one configured, and is an
  error when there are several, so a call never lands on a device by accident.
  """
  @spec resolve(name() | nil) :: {:ok, name()} | {:error, String.t()}
  def resolve(nil) do
    case names() do
      [name] -> {:ok, name}
      [] -> {:error, "No device is configured"}
      names -> {:error, "Several devices are configured, so pass device: one of #{list(names)}"}
    end
  end

  def resolve(name) when is_binary(name) do
    names = names()

    if name in names,
      do: {:ok, name},
      else: {:error, "No device named #{inspect(name)}. Configured: #{list(names)}"}
  end

  defp list(names), do: Enum.join(names, ", ")
end
