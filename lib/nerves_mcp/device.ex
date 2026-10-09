defmodule NervesMCP.Device do
  @moduledoc """
  One device's processes: its output history, its connection and its probe.

  Each registers under the device's name (see `NervesMCP.Devices.via/2`), so a
  crash restarts that process for that device and leaves every other device's
  connection alone.
  """

  use Supervisor

  alias NervesMCP.Devices

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: Devices.via(name, __MODULE__))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    connection = Keyword.fetch!(opts, :connection)
    {:ok, module} = Devices.module(connection)

    Supervisor.init(
      [
        {NervesMCP.History, device: name},
        {module, device: name, connection: connection},
        {NervesMCP.DeviceProbe, device: name}
      ],
      strategy: :one_for_one
    )
  end
end
