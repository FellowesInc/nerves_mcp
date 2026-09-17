defmodule NervesMCP.Connection.SSH do
  @moduledoc """
  Handles SSH connection to a Nerves device.

  Uses a Port to maintain an interactive SSH session and evaluate Elixir code.
  Automatically reconnects if the SSH connection drops (e.g. device reboot).
  """

  use GenServer

  alias NervesMCP.Connection.EvalTemplate
  alias NervesMCP.Connection.EvalTemplate.Matcher

  require Logger

  @initial_retry_delay 1_000
  @max_retry_delay 30_000
  @connect_deadline_ms 20_000

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

  @spec reconnect() :: :ok | {:error, String.t()}
  def reconnect() do
    GenServer.call(__MODULE__, :reconnect, 10_000)
  end

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      waiting: nil,
      console: nil,
      retry_delay: @initial_retry_delay,
      data_seen?: false,
      fallback?: false
    }

    {:ok, connect(state)}
  end

  defp connect(state) do
    config = Application.get_env(:nerves_mcp, :connection, [])

    host = target_host(config, state.fallback?)
    user = Keyword.get(config, :user, "root")
    port = Keyword.get(config, :port, 22)
    pass = Keyword.get(config, :pass)

    ssh_args = [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=2",
      "-o",
      "ConnectTimeout=10",
      "-p",
      "#{port}",
      "-tt",
      "#{user}@#{host}"
    ]

    {executable, args} =
      case pass do
        nil ->
          {System.find_executable("ssh"), ssh_args}

        password when is_binary(password) ->
          case System.find_executable("sshpass") do
            nil ->
              raise "sshpass executable not found in PATH but --pass was provided"

            sshpass ->
              {sshpass, ["-p", password, "ssh" | ssh_args]}
          end
      end

    try do
      port_ref =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          args: args,
          env: [{~c"TERM", ~c"dumb"}]
        ])

      Logger.info("SSH connection started to #{user}@#{host}:#{port}")
      Process.send_after(self(), {:connect_deadline, port_ref}, connect_deadline_ms())
      %{state | port: port_ref, data_seen?: false}
    rescue
      e ->
        Logger.error("Failed to start SSH connection: #{inspect(e)}")
        schedule_reconnect(state)
        %{state | port: nil, data_seen?: false}
    end
  end

  defp connect_deadline_ms() do
    :nerves_mcp
    |> Application.get_env(:connection, [])
    |> Keyword.get(:connect_deadline_ms, @connect_deadline_ms)
  end

  # `fallback_host` is optional. Without it every attempt goes to `host`.
  defp target_host(config, fallback?) do
    case {fallback?, Keyword.get(config, :fallback_host)} do
      {true, fallback} when is_binary(fallback) -> fallback
      _no_fallback -> Keyword.fetch!(config, :host)
    end
  end

  defp schedule_reconnect(state) do
    Logger.info("Scheduling SSH reconnection in #{state.retry_delay}ms")
    Process.send_after(self(), :reconnect, state.retry_delay)
  end

  defp next_retry_delay(current) do
    min(current * 2, @max_retry_delay)
  end

  # Nothing came back from this host, so the next attempt tries the other one.
  # A connection that did work stays where it is.
  defp next_host(%{data_seen?: false, fallback?: fallback?}), do: not fallback?
  defp next_host(%{fallback?: fallback?}), do: fallback?

  # An explicit reconnect kills a live attempt, so it picks the next host the
  # same way the connect deadline does. The polling tools call `reconnect/0`
  # after a 5 s eval failure, well inside the 20 s deadline, so without this the
  # same silent host is restarted forever and `fallback_host` is never tried. An
  # attempt that already exited chose its host on the way out.
  defp close_attempt(%{port: nil} = state), do: state

  defp close_attempt(state) do
    Port.close(state.port)
    %{state | port: nil, fallback?: next_host(state)}
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

  def handle_call(:reconnect, _from, state) do
    state = state |> reply_waiting({:error, "Reconnecting"}) |> close_attempt()

    new_state = connect(state)
    {:reply, if(new_state.port, do: :ok, else: {:error, "reconnect failed"}), new_state}
  end

  def handle_call({op, _payload, _timeout}, _from, %{port: nil} = state)
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
      matcher: EvalTemplate.matcher(marker, :elixir),
      timeout: timeout,
      tag: :timeout
    )
  end

  def handle_call({:eval_output, code, timeout}, from, state) do
    marker = EvalTemplate.marker()

    start_call(state, from,
      data: EvalTemplate.eval_output(code, marker) <> "\n\n",
      matcher: EvalTemplate.matcher(marker, :elixir),
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

  def handle_call({:probe, _timeout}, _from, %{port: nil} = state) do
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
      matcher: EvalTemplate.matcher(marker, :elixir),
      timeout: timeout,
      tag: :probe_timeout
    )
  end

  @impl true
  def handle_cast({:send_raw, _data}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_raw, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    NervesMCP.History.push(data)
    state = note_data(state)

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

  # ssh can sit for minutes on a name that won't resolve, and on macOS an mDNS
  # name that has gone quiet does exactly that. Give up on a silent attempt and
  # try the other host.
  def handle_info({:connect_deadline, port}, %{port: port, data_seen?: false} = state) do
    Logger.warning("No response from the device within the connect deadline, reconnecting")

    Port.close(state.port)

    new_state = %{
      state
      | port: nil,
        retry_delay: next_retry_delay(state.retry_delay),
        fallback?: next_host(state)
    }

    schedule_reconnect(new_state)
    {:noreply, new_state}
  end

  def handle_info({:connect_deadline, _port}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("SSH process exited with status: #{status}")

    state = reply_waiting(state, {:error, "SSH connection closed unexpectedly"})

    if state.console do
      {pid, _ref} = state.console
      send(pid, {:console_data, "\r\n--- SSH connection lost, reconnecting... ---\r\n"})
    end

    new_state = %{
      state
      | port: nil,
        retry_delay: next_retry_delay(state.retry_delay),
        fallback?: next_host(state)
    }

    schedule_reconnect(new_state)
    {:noreply, new_state}
  end

  def handle_info(:reconnect, %{port: nil} = state) do
    Logger.info("Attempting SSH reconnection...")
    new_state = connect(state)

    if new_state.port do
      # Notify console of reconnection
      if new_state.console do
        {pid, _ref} = new_state.console
        send(pid, {:console_data, "\r\n--- SSH reconnected ---\r\n"})
      end
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
    if state.port do
      Port.command(state.port, "#iex:break\n")
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
    if state.port do
      Port.close(state.port)
    end

    :ok
  end

  defp start_call(state, from, opts) do
    Port.command(state.port, Keyword.fetch!(opts, :data))

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

  # The backoff resets on device output, not on `Port.open`. Opening succeeds
  # even when ssh then exits 255 because the host does not resolve, and retrying
  # that every two seconds forever is no use to anyone.
  defp note_data(%{data_seen?: true} = state), do: state
  defp note_data(state), do: %{state | data_seen?: true, retry_delay: @initial_retry_delay}
end
