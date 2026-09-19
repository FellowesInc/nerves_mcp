defmodule NervesMCP.Connection.SSH do
  @moduledoc """
  Handles SSH connection to a Nerves device.

  Uses a Port to maintain an interactive SSH session and evaluate Elixir code.
  Automatically reconnects if the SSH connection drops (e.g. device reboot).

  A host given as a name is the device's mDNS name, its hostname plus `.local`.
  While the name answers, the address it resolves to is cached (see
  `NervesMCP.Connection.AddressCache`). When it stops answering, attempts
  alternate between the name and the cached address. A connection made to an
  address, cached or given with `set_address/1`, runs nothing until the device
  on it reports the expected hostname. One that reports another hostname is
  closed and the address dropped, since DHCP has given it to another device.
  """

  use GenServer

  alias NervesMCP.Connection.AddressCache
  alias NervesMCP.Connection.EvalTemplate
  alias NervesMCP.Connection.EvalTemplate.Matcher

  require Logger

  @initial_retry_delay 1_000
  @max_retry_delay 30_000
  @connect_deadline_ms 20_000
  @verify_timeout 5_000
  @hostname_code "{:ok, hostname} = :inet.gethostname()\nto_string(hostname)"
  @ask "Ask the user for the device's IP address, then call set_device_address."

  @type result() :: {:ok, String.t()} | {:error, String.t()}

  @typedoc """
  What the connection is trying, the address cached for its host, and why it
  can't reach the device when there is something the user can do about it.
  """
  @type status() :: %{
          target: String.t(),
          address: String.t() | nil,
          reason: String.t() | nil
        }

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

  @doc """
  Try `address` for the configured name, for when the name won't resolve.

  Answers once the device on `address` has reported its hostname, or the attempt
  failed. A match is cached. The name stays primary either way.
  """
  @spec set_address(String.t()) :: result()
  def set_address(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, _ip} ->
        timeout = connect_deadline_ms() + @verify_timeout + 1_000
        GenServer.call(__MODULE__, {:set_address, address}, timeout)

      {:error, :einval} ->
        {:error, "#{inspect(address)} is not an IP address"}
    end
  end

  @spec status() :: status()
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    host = :nerves_mcp |> Application.get_env(:connection, []) |> Keyword.fetch!(:host)

    cache_dir =
      Application.get_env(
        :nerves_mcp,
        :address_cache_dir,
        :filename.basedir(:user_cache, "nerves_mcp")
      )

    state = %{
      port: nil,
      waiting: nil,
      console: nil,
      retry_delay: @initial_retry_delay,
      data_seen?: false,
      host: host,
      hostname: expected_hostname(:inet.parse_address(String.to_charlist(host)), host),
      cache: AddressCache.path(cache_dir),
      target: :name,
      verified?: true,
      problem: nil,
      address_from: nil
    }

    {:ok, connect(state)}
  end

  # A Nerves device's mDNS name is its hostname plus `.local`, so the first label
  # of a configured name is what the device reports as its hostname. An address
  # names no device and is never checked.
  defp expected_hostname({:ok, _ip}, _host), do: nil
  defp expected_hostname({:error, :einval}, host), do: first_label(host)

  defp first_label(name), do: name |> String.split(".") |> hd() |> String.downcase()

  defp connect(state) do
    config = Application.get_env(:nerves_mcp, :connection, [])

    host = target_host(state)
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

      log_target(state)
      Logger.info("SSH connection started to #{user}@#{host}:#{port}")
      Process.send_after(self(), {:connect_deadline, port_ref}, connect_deadline_ms())
      %{state | port: port_ref, data_seen?: false, verified?: state.target == :name}
    rescue
      e ->
        Logger.error("Failed to start SSH connection: #{inspect(e)}")
        schedule_reconnect(state)
        %{state | port: nil, data_seen?: false}
    end
  end

  defp target_host(%{target: :name, host: host}), do: host
  defp target_host(%{target: {:address, address}}), do: address

  defp log_target(%{target: :name}), do: :ok

  defp log_target(%{target: {:address, address}} = state),
    do: Logger.info("Trying address #{address} for #{state.host}")

  defp connect_deadline_ms() do
    :nerves_mcp
    |> Application.get_env(:connection, [])
    |> Keyword.get(:connect_deadline_ms, @connect_deadline_ms)
  end

  defp schedule_reconnect(state) do
    Logger.info("Scheduling SSH reconnection in #{state.retry_delay}ms")
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

  def handle_call(:reconnect, _from, state) do
    state = drop_calls(state, {:error, "Reconnecting"})

    new_state = connect(%{state | port: nil, target: :name})
    {:reply, if(new_state.port, do: :ok, else: {:error, "reconnect failed"}), new_state}
  end

  def handle_call({:set_address, _address}, _from, %{hostname: nil} = state) do
    reply =
      {:error,
       "#{state.host} is an address already. set_device_address is for a device name " <>
         "that won't resolve."}

    {:reply, reply, state}
  end

  def handle_call({:set_address, address}, from, state) do
    state = drop_calls(state, {:error, "Reconnecting to #{address}"})

    {:noreply, connect(%{state | port: nil, target: {:address, address}, address_from: from})}
  end

  def handle_call(:status, _from, state) do
    status = %{target: target_host(state), address: cached_address(state), reason: reason(state)}
    {:reply, status, state}
  end

  def handle_call({op, _payload, _timeout}, _from, %{port: nil} = state)
      when op in [:eval, :eval_output, :shell_eval, :shell_eval_output] do
    {:reply, {:error, "Device not connected (reconnecting...)"}, state}
  end

  # Until the device on an address has said who it is, it may be somebody
  # else's device.
  def handle_call({op, _payload, _timeout}, _from, %{verified?: false} = state)
      when op in [:eval, :eval_output, :shell_eval, :shell_eval_output] do
    {:reply, {:error, "Device not connected (checking #{target_host(state)} is #{state.host})"},
     state}
  end

  # One expression at a time. A second one would overwrite the first caller's
  # marker and strand it until its timeout.
  def handle_call({op, _payload, _timeout}, _from, %{waiting: waiting} = state)
      when op in [:eval, :eval_output, :shell_eval, :shell_eval_output] and not is_nil(waiting) do
    {:reply, {:error, "busy"}, state}
  end

  def handle_call({:eval, code, timeout}, from, state) do
    marker = EvalTemplate.marker()

    {:noreply,
     start_call(state, from,
       data: EvalTemplate.eval(code, marker) <> "\n\n",
       matcher: EvalTemplate.matcher(marker, :elixir),
       timeout: timeout,
       tag: :timeout
     )}
  end

  def handle_call({:eval_output, code, timeout}, from, state) do
    marker = EvalTemplate.marker()

    {:noreply,
     start_call(state, from,
       data: EvalTemplate.eval_output(code, marker) <> "\n\n",
       matcher: EvalTemplate.matcher(marker, :elixir),
       timeout: timeout,
       tag: :timeout
     )}
  end

  def handle_call({:shell_eval, command, timeout}, from, state) do
    marker = EvalTemplate.marker()

    {:noreply,
     start_call(state, from,
       data: EvalTemplate.shell_eval(command, marker),
       matcher: EvalTemplate.matcher(marker, :shell),
       timeout: timeout,
       tag: :timeout
     )}
  end

  def handle_call({:shell_eval_output, command, timeout}, from, state) do
    marker = EvalTemplate.marker()

    {:noreply,
     start_call(state, from,
       data: EvalTemplate.shell_eval_output(command, marker),
       matcher: EvalTemplate.matcher(marker, :shell),
       timeout: timeout,
       tag: :timeout
     )}
  end

  def handle_call({:probe, _timeout}, _from, %{port: nil} = state) do
    {:reply, :down, state}
  end

  def handle_call({:probe, _timeout}, _from, %{verified?: false} = state) do
    {:reply, :down, state}
  end

  def handle_call({:probe, _timeout}, _from, %{waiting: waiting} = state)
      when not is_nil(waiting) do
    {:reply, :busy, state}
  end

  def handle_call({:probe, timeout}, from, state) do
    marker = EvalTemplate.marker()

    {:noreply,
     start_call(state, from,
       data: EvalTemplate.eval(EvalTemplate.probe_code(), marker) <> "\n\n",
       matcher: EvalTemplate.matcher(marker, :elixir),
       timeout: timeout,
       tag: :probe_timeout
     )}
  end

  @impl true
  def handle_cast({:send_raw, _data}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_raw, _data}, %{verified?: false} = state) do
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
            {:noreply, done(waiting.from, result, %{state | waiting: nil})}

          {:cont, matcher} ->
            {:noreply, %{state | waiting: %{waiting | matcher: matcher}}}
        end
    end
  end

  # ssh can sit for minutes on a name that won't resolve, and on macOS an mDNS
  # name that has gone quiet does exactly that. Give up on a silent attempt and
  # retry with backoff, so a name that comes back after a reboot is picked up.
  def handle_info({:connect_deadline, port}, %{port: port, data_seen?: false} = state) do
    Logger.warning("No response from the device within the connect deadline, reconnecting")

    Port.close(state.port)

    {:noreply, state |> fall_back() |> retry()}
  end

  def handle_info({:connect_deadline, _port}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("SSH process exited with status: #{status}")

    state = reply_waiting(state, {:error, "SSH connection closed unexpectedly"})

    if state.console do
      {pid, _ref} = state.console
      send(pid, {:console_data, "\r\n--- SSH connection lost, reconnecting... ---\r\n"})
    end

    {:noreply, state |> fall_back() |> retry()}
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

  # Answered, but not with a hostname. Nothing to check it against, so it is no
  # more use than an address that never answered.
  def handle_info({:timeout, :verify}, %{waiting: %{from: :verify}} = state) do
    Logger.warning("#{target_host(state)} never reported its hostname, dropping it")
    Port.close(state.port)

    {:noreply, %{state | waiting: nil} |> fall_back() |> retry()}
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

    %{state | waiting: waiting}
  end

  defp done(:verify, result, state) do
    result
    |> String.trim()
    |> String.trim(~s|"|)
    |> first_label()
    |> check_hostname(state)
  end

  defp done(from, result, state) do
    GenServer.reply(from, {:ok, result})
    state
  end

  defp check_hostname(hostname, %{hostname: hostname, target: {:address, address}} = state) do
    Logger.info("Verified #{address} is #{state.host}")
    AddressCache.put(state.cache, hostname, address)

    reply_address(
      %{state | verified?: true, problem: nil},
      {:ok, "#{address} answered as #{hostname}. Connected, and cached for next time."}
    )
  end

  defp check_hostname(reported, %{target: {:address, address}} = state) do
    Logger.warning("#{address} answered as #{reported}, not #{state.hostname}, dropping it")
    AddressCache.delete(state.cache, state.hostname, address)
    Port.close(state.port)

    retry(%{state | target: :name, problem: {:rejected, address, reported}})
  end

  # The name is trusted as soon as it answers, since it is the device's own.
  defp answered(%{target: :name} = state) do
    learn(state)
    %{state | problem: nil}
  end

  defp answered(state) do
    marker = EvalTemplate.marker()

    start_call(state, :verify,
      data: EvalTemplate.eval(@hostname_code, marker) <> "\n\n",
      matcher: EvalTemplate.matcher(marker, :elixir),
      timeout: @verify_timeout,
      tag: :timeout
    )
  end

  defp learn(%{hostname: nil}), do: :ok

  # Resolving an mDNS name can take seconds, so it happens off this process.
  defp learn(state) do
    {:ok, _pid} = Task.start(AddressCache, :learn, [state.cache, state.hostname, state.host])
    :ok
  end

  # Where the next attempt goes after this one ended. A name that never answered
  # hands over to the cached address, and anything else goes back to the name,
  # which stays primary.
  defp fall_back(%{hostname: nil} = state), do: state
  defp fall_back(%{data_seen?: true, verified?: true} = state), do: %{state | target: :name}

  defp fall_back(%{target: :name} = state) do
    case cached_address(state) do
      nil -> put_problem(state, :no_address)
      address -> %{state | target: {:address, address}}
    end
  end

  defp fall_back(%{target: {:address, address}} = state) do
    %{put_problem(state, {:silent_address, address}) | target: :name}
  end

  # A rejected address says more than "no address known", which is what the
  # next failed attempt on the name would report.
  defp put_problem(%{problem: {:rejected, _address, _reported}} = state, :no_address), do: state
  defp put_problem(state, problem), do: %{state | problem: problem}

  defp retry(state) do
    state = reply_address(state, {:error, reason(state)})
    new_state = %{state | port: nil, retry_delay: next_retry_delay(state.retry_delay)}
    schedule_reconnect(new_state)
    new_state
  end

  defp cached_address(%{hostname: nil}), do: nil
  defp cached_address(state), do: AddressCache.lookup(state.cache, state.hostname)

  defp reason(%{problem: nil}), do: nil

  defp reason(%{problem: :no_address} = state),
    do: "#{state.host} isn't answering and no address is known for this device. " <> @ask

  defp reason(%{problem: {:silent_address, address}} = state) do
    "#{state.host} isn't answering and neither is #{address}. If the device should be up " <>
      "by now, ask the user for its IP address, then call set_device_address."
  end

  defp reason(%{problem: {:rejected, address, reported}} = state) do
    "#{address} answered as #{reported}, not #{state.hostname}. DHCP has likely given it " <>
      "to another device, so it is no longer used. " <> @ask
  end

  # Closes the session and answers everyone waiting on it.
  defp drop_calls(state, reply) do
    if state.port do
      Port.close(state.port)
    end

    state
    |> reply_waiting(reply)
    |> reply_address(reply)
  end

  defp reply_address(%{address_from: nil} = state, _reply), do: state

  defp reply_address(state, reply) do
    GenServer.reply(state.address_from, reply)
    %{state | address_from: nil}
  end

  defp reply_waiting(%{waiting: nil} = state, _reply), do: state

  defp reply_waiting(%{waiting: waiting} = state, reply) do
    cancel_timer(waiting)
    reply_caller(waiting.from, reply)
    %{state | waiting: nil}
  end

  # The hostname check has no caller, and the attempt it belonged to is going.
  defp reply_caller(:verify, _reply), do: :ok
  defp reply_caller(from, reply), do: GenServer.reply(from, reply)

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

  defp note_data(state),
    do: answered(%{state | data_seen?: true, retry_delay: @initial_retry_delay})
end
