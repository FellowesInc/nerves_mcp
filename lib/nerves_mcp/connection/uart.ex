defmodule NervesMCP.Connection.UART do
  @moduledoc """
  Handles UART serial connection to a Nerves device.

  Sends Elixir code to the device's IEx shell and captures output.
  Automatically reconnects if the serial port is unavailable or disconnected.
  """

  use GenServer

  alias NervesMCP.Connection.EvalTemplate
  alias NervesMCP.Connection.EvalTemplate.Matcher

  require Logger

  @default_port "/dev/ttyUSB0"
  @default_speed 115_200
  @initial_retry_delay 1_000
  @max_retry_delay 30_000

  @type result() :: {:ok, String.t()} | {:error, String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec eval(String.t(), non_neg_integer()) :: result()
  def eval(code, timeout \\ 15000) do
    GenServer.call(__MODULE__, {:eval, code, timeout}, timeout + 1000)
  end

  @spec eval_output(String.t(), non_neg_integer()) :: result()
  def eval_output(code, timeout \\ 15000) do
    GenServer.call(__MODULE__, {:eval_output, code, timeout}, timeout + 1000)
  end

  @doc "Run a raw shell command (no Elixir wrapping). Used in degraded shell mode."
  @spec shell_eval(String.t(), non_neg_integer()) :: result()
  def shell_eval(command, timeout \\ 15000) do
    GenServer.call(__MODULE__, {:shell_eval, command, timeout}, timeout + 1000)
  end

  @doc "Run a raw shell command and capture stdout/stderr plus exit code."
  @spec shell_eval_output(String.t(), non_neg_integer()) :: result()
  def shell_eval_output(command, timeout \\ 15000) do
    GenServer.call(__MODULE__, {:shell_eval_output, command, timeout}, timeout + 1000)
  end

  @doc """
  Probe what is on the other end. Returns:

    * `{:ok, result}` — an Elixir result came back (classify it upstream)
    * `:noise`        — bytes came back but no valid Elixir result
    * `:down`         — not connected / nothing came back
    * `:busy`         — an evaluation is already in flight
  """
  @spec probe(non_neg_integer()) :: {:ok, String.t()} | :noise | :down | :busy
  def probe(timeout \\ 4_000) do
    GenServer.call(__MODULE__, {:probe, timeout}, timeout + 1000)
  end

  @spec attach_console(pid()) :: :ok
  def attach_console(pid \\ self()) do
    GenServer.call(__MODULE__, {:attach_console, pid})
  end

  @spec detach_console() :: :ok
  def detach_console() do
    GenServer.call(__MODULE__, :detach_console)
  end

  @spec send_raw(iodata()) :: :ok
  def send_raw(data) do
    GenServer.cast(__MODULE__, {:send_raw, data})
  end

  @impl true
  def init(_opts) do
    state = %{
      uart: nil,
      connected: false,
      waiting: nil,
      console: nil,
      retry_delay: @initial_retry_delay
    }

    {:ok, connect(state)}
  end

  defp connect(state) do
    config = Application.get_env(:nerves_mcp, :connection, [])

    port = Keyword.get(config, :port, @default_port)
    speed = Keyword.get(config, :speed, @default_speed)

    # Start a new UART process if we don't have one
    uart =
      case state.uart do
        nil ->
          {:ok, pid} = Circuits.UART.start_link()
          pid

        existing ->
          # Close any existing connection before reconnecting
          Circuits.UART.close(existing)
          existing
      end

    case Circuits.UART.open(uart, port, speed: speed, active: true) do
      :ok ->
        Logger.info("UART connection opened on #{port}")
        %{state | uart: uart, connected: true, retry_delay: @initial_retry_delay}

      {:error, reason} ->
        Logger.error("Failed to open UART on #{port}: #{inspect(reason)}")
        schedule_reconnect(state)
        %{state | uart: uart, connected: false}
    end
  end

  defp schedule_reconnect(state) do
    Logger.info("Scheduling UART reconnection in #{state.retry_delay}ms")
    Process.send_after(self(), :reconnect, state.retry_delay)
  end

  defp next_retry_delay(current) do
    min(current * 2, @max_retry_delay)
  end

  @impl true
  def handle_call({:attach_console, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | console: {pid, ref}}}
  end

  def handle_call(:detach_console, _from, %{console: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | console: nil}}
  end

  def handle_call(:detach_console, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({op, _payload, _timeout}, _from, %{connected: false} = state)
      when op in [:eval, :eval_output, :shell_eval, :shell_eval_output] do
    {:reply, {:error, "Device not connected (reconnecting...)"}, state}
  end

  # One expression at a time. A second one would overwrite the first caller's
  # marker and strand it until its timeout.
  def handle_call({op, _payload, _timeout}, _from, %{waiting: waiting} = state)
      when op in [:eval, :eval_output, :shell_eval, :shell_eval_output] and not is_nil(waiting) do
    {:reply, {:error, "busy"}, state}
  end

  def handle_call({:eval, code, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.eval(code, marker) <> "\n\n",
      matcher: elixir_matcher(marker),
      timeout: timeout,
      tag: :timeout
    )
  end

  def handle_call({:eval_output, code, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.eval_output(code, marker) <> "\n\n",
      matcher: elixir_matcher(marker),
      timeout: timeout,
      tag: :timeout
    )
  end

  def handle_call({:shell_eval, command, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.shell_eval(command, marker),
      matcher: EvalTemplate.matcher(marker, :shell),
      timeout: timeout,
      tag: :timeout
    )
  end

  def handle_call({:shell_eval_output, command, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.shell_eval_output(command, marker),
      matcher: EvalTemplate.matcher(marker, :shell),
      timeout: timeout,
      tag: :timeout
    )
  end

  def handle_call({:probe, _timeout}, _from, %{connected: false} = state) do
    {:reply, :down, state}
  end

  def handle_call({:probe, _timeout}, _from, %{waiting: waiting} = state)
      when not is_nil(waiting) do
    {:reply, :busy, state}
  end

  def handle_call({:probe, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.eval(EvalTemplate.probe_code(), marker) <> "\n\n",
      matcher: elixir_matcher(marker),
      timeout: timeout,
      tag: :probe_timeout
    )
  end

  @impl true
  def handle_cast({:send_raw, _data}, %{connected: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_raw, data}, state) do
    Circuits.UART.write(state.uart, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.error("UART error: #{inspect(reason)}")

    state = reply_waiting(state, {:error, "UART connection error: #{inspect(reason)}"})

    if state.console do
      {pid, _ref} = state.console
      send(pid, {:console_data, "\r\n--- UART connection lost, reconnecting... ---\r\n"})
    end

    new_state = %{state | connected: false, retry_delay: next_retry_delay(state.retry_delay)}

    schedule_reconnect(new_state)
    {:noreply, new_state}
  end

  def handle_info({:circuits_uart, _port, data}, state) do
    NervesMCP.History.push(data)

    case state.waiting do
      nil ->
        if state.console do
          {pid, _ref} = state.console
          send(pid, {:console_data, data})
        end

        {:noreply, state}

      waiting ->
        case Matcher.feed(waiting.matcher, data) do
          {:done, result} ->
            cancel_timer(waiting)
            GenServer.reply(waiting.from, {:ok, result})
            {:noreply, %{state | waiting: nil}}

          {:cont, matcher} ->
            {:noreply, %{state | waiting: %{waiting | matcher: matcher}}}
        end
    end
  end

  def handle_info(:reconnect, %{connected: false} = state) do
    Logger.info("Attempting UART reconnection...")
    new_state = connect(state)

    if new_state.connected and new_state.console do
      {pid, _ref} = new_state.console
      send(pid, {:console_data, "\r\n--- UART reconnected ---\r\n"})
    end

    {:noreply, new_state}
  end

  def handle_info(:reconnect, state) do
    # Already connected, ignore
    {:noreply, state}
  end

  def handle_info({:probe_timeout, from}, %{waiting: %{from: from} = waiting} = state) do
    GenServer.reply(from, if(Matcher.output?(waiting.matcher), do: :noise, else: :down))
    {:noreply, %{state | waiting: nil}}
  end

  def handle_info({:timeout, from}, %{waiting: %{from: from}} = state) do
    # The expression that timed out may be half typed on the device, where it
    # would swallow every later eval.
    if state.connected do
      Circuits.UART.write(state.uart, "#iex:break\n")
    end

    GenServer.reply(from, {:error, "Timeout waiting for device response"})
    {:noreply, %{state | waiting: nil}}
  end

  # A timer for a call that already answered. Its caller is long gone.
  def handle_info({tag, _from}, state) when tag in [:timeout, :probe_timeout] do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{console: {pid, ref}} = state) do
    {:noreply, %{state | console: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.uart do
      Circuits.UART.close(state.uart)
    end

    :ok
  end

  # A serial line carries no echo to anchor against the way a pty does, so the
  # newline the device prints before the marker is what marks the printed line.
  defp elixir_matcher(marker) do
    EvalTemplate.matcher(marker, :elixir, anchor: :leading)
  end

  defp start_call(state, from, opts) do
    Circuits.UART.write(state.uart, Keyword.fetch!(opts, :data))

    message = {Keyword.fetch!(opts, :tag), from}
    timer = Process.send_after(self(), message, Keyword.fetch!(opts, :timeout))

    waiting = %{
      from: from,
      matcher: Keyword.fetch!(opts, :matcher),
      timer: timer,
      message: message
    }

    {:noreply, %{state | waiting: waiting}}
  end

  defp reply_waiting(%{waiting: nil} = state, _reply), do: state

  defp reply_waiting(%{waiting: waiting} = state, reply) do
    cancel_timer(waiting)
    GenServer.reply(waiting.from, reply)
    %{state | waiting: nil}
  end

  # Cancelling is not enough. The timer may already have fired, and the message
  # would then arrive for a call that is finished.
  defp cancel_timer(waiting) do
    Process.cancel_timer(waiting.timer, info: false)
    message = waiting.message

    receive do
      ^message -> :ok
    after
      0 -> :ok
    end
  end
end
