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

  The configured list is what should run. What is running is in the registry: a
  device's connection registers under `{name, :connection}` with its module and
  settings as the value, so `module/1` and `connection/1` answer from the live
  device rather than the application env.
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

  @doc """
  Check the devices before anything starts, so a bad entry fails with a message
  that names it rather than as a crash deep in a supervisor. Returns the devices.
  """
  @spec validate!([device()]) :: [device()]
  def validate!(devices) do
    Enum.each(devices, &validate_device!/1)
    names = Enum.map(devices, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] -> devices
      [name | _] -> raise ArgumentError, "device #{inspect(name)} is configured more than once"
    end
  end

  defp validate_device!({name, connection}) when is_binary(name) and name != "" do
    unless Keyword.keyword?(connection) do
      raise ArgumentError, "device #{inspect(name)} needs a keyword list of connection settings"
    end

    case Keyword.get(connection, :type) do
      :ssh ->
        require_setting!(name, connection, :host)

      :uart ->
        require_setting!(name, connection, :port)

      other ->
        raise ArgumentError,
              "device #{inspect(name)} has type #{inspect(other)}, not :ssh or :uart"
    end
  end

  defp validate_device!(other) do
    raise ArgumentError,
          "invalid device #{inspect(other)}, expected {name, connection} with a non-empty string name"
  end

  defp require_setting!(name, connection, key) do
    unless Keyword.has_key?(connection, key) do
      raise ArgumentError, "device #{inspect(name)} has no #{inspect(key)}"
    end
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

  @doc "The settings of a device's running connection, or `[]` when it isn't running."
  @spec connection(name()) :: keyword()
  def connection(name) do
    case running(name) do
      {:ok, {_module, connection}} -> connection
      :error -> []
    end
  end

  @doc "The module of a device's running connection."
  @spec module(name()) :: {:ok, module()} | {:error, String.t()}
  def module(name) do
    case running(name) do
      {:ok, {module, _connection}} -> {:ok, module}
      :error -> {:error, "No connection is running for device #{inspect(name)}"}
    end
  end

  defp running(name) do
    case Registry.lookup(@registry, {name, :connection}) do
      [{_pid, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc "The connection module that drives these settings."
  @spec module_for(keyword()) :: module()
  def module_for(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart -> UART
      :ssh -> SSH
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

  @doc """
  Where a device's process for `role` is registered. The connection's role is
  `:connection`, whichever module drives it.
  """
  @spec via(name(), module() | :connection) :: GenServer.name()
  def via(name, role), do: {:via, Registry, {@registry, {name, role}}}

  @doc "Registers a device's connection with its module and settings as the value."
  @spec connection_via(name(), module(), keyword()) :: GenServer.name()
  def connection_via(name, module, connection),
    do: {:via, Registry, {@registry, {name, :connection}, {module, connection}}}

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
