defmodule NervesMCP.Test.WaitInputConsole do
  @moduledoc """
  A serial console held by `nbtty --wait-input`, in place of `Circuits.UART`.

  Pass it as the connection's `:uart_module`. It takes the four calls
  `NervesMCP.Connection.UART` makes and plays the device behind them. Each write is
  cut into reads of `read_size/1` bytes, all of it in one read by default, since
  that is the unit nbtty works in.

  Until a read carries a carriage return, nbtty drops input and output, and it
  drops that read too. After it, input reaches IEx, and each END marker is answered
  with a firmware UUID the way IEx prints one. Nothing is echoed.

  The console registers under this module's name when opened, so a test can reach
  it while the connection holds it.

  ### API

    * `read_size/1` — cut every later write into reads of this many bytes
    * `typed/0` — everything that has reached IEx
  """

  use GenServer

  @eos "\e[999H"
  @end_marker ~r/([0-9A-F]{16})_END/

  @spec read_size(pos_integer()) :: :ok
  def read_size(bytes), do: GenServer.call(__MODULE__, {:read_size, bytes})

  @spec typed() :: binary()
  def typed(), do: GenServer.call(__MODULE__, :typed)

  @spec start_link() :: GenServer.on_start()
  def start_link(), do: GenServer.start_link(__MODULE__, nil)

  @spec open(GenServer.server(), String.t(), keyword()) :: :ok
  def open(pid, name, _opts), do: GenServer.call(pid, {:open, name})

  @spec write(GenServer.server(), iodata()) :: :ok
  def write(pid, data), do: GenServer.call(pid, {:write, IO.iodata_to_binary(data)})

  @spec close(GenServer.server()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @impl true
  def init(nil) do
    {:ok, %{owner: nil, name: nil, active: false, read_size: :all, typed: "", pending: ""}}
  end

  @impl true
  def handle_call({:open, name}, {owner, _tag}, state) do
    unless Process.whereis(__MODULE__), do: Process.register(self(), __MODULE__)
    {:reply, :ok, %{state | owner: owner, name: name}}
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | owner: nil}}

  def handle_call({:read_size, bytes}, _from, state),
    do: {:reply, :ok, %{state | read_size: bytes}}

  def handle_call(:typed, _from, state), do: {:reply, state.typed, state}

  def handle_call({:write, data}, _from, state) do
    {:reply, :ok, data |> reads(state.read_size) |> Enum.reduce(state, &read/2)}
  end

  defp reads(data, :all), do: [data]

  defp reads(data, size) when byte_size(data) > size do
    <<read::binary-size(^size), rest::binary>> = data
    [read | reads(rest, size)]
  end

  defp reads(data, _size), do: [data]

  defp read(data, %{active: false} = state) do
    if String.contains?(data, "\r") do
      print(state, @eos <> "\r\n")
      %{state | active: true}
    else
      state
    end
  end

  defp read(data, state) do
    pending = state.pending <> data

    case Regex.scan(@end_marker, pending, return: :index) do
      [] ->
        %{state | typed: state.typed <> data, pending: pending}

      matches ->
        for [_match, {start, length}] <- matches do
          marker = binary_part(pending, start, length)
          print(state, "\r\n#{marker}_START\r\n\"0123abcd\"\r\n#{marker}_END\r\n")
        end

        [{start, length}, _marker] = List.last(matches)
        rest = binary_part(pending, start + length, byte_size(pending) - start - length)
        %{state | typed: state.typed <> data, pending: rest}
    end
  end

  defp print(%{owner: nil}, _data), do: :ok
  defp print(state, data), do: send(state.owner, {:circuits_uart, state.name, data})
end
