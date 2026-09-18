defmodule NervesMCP.CLI do
  @moduledoc """
  CLI argument parsing and connection setup for NervesMCP.

  CLI args override values from config/config.exs. If no args are provided
  but config exists, the config values are used as-is.

  Supports two connection modes:

  **Serial (UART):**
      nerves_mcp /dev/ttyUSB0
      nerves_mcp --serial /dev/ttyUSB0 --speed 115200

  **SSH:**
      nerves_mcp nerves.local
      nerves_mcp --ssh nerves.local --user root --ssh-port 22

  Common options:
      --port PORT    MCP server port (default: 13000)
      --no-repl      Don't read stdin; block instead

  Without `--no-repl` the foreground is `repl/0`, an `IO.gets` loop that
  returns on stdin EOF and takes the VM with it. `--no-repl` blocks forever
  instead, so the server survives EOF and can run from a background shell or
  under a process supervisor.
  """

  @serial_patterns ["/dev/tty", "/dev/cu.", "/dev/serial"]

  @typedoc "Parsed CLI configuration, as stored in the application env."
  @type config() :: %{
          connection: keyword(),
          mcp_port: pos_integer(),
          repl?: boolean()
        }

  @spec main([String.t()]) :: :ok
  def main(args) do
    args
    |> run()
    |> serve()
  end

  @doc """
  Block on the configured foreground: the stdin repl, or forever under
  `--no-repl`.
  """
  @spec serve(config()) :: :ok
  def serve(%{repl?: true}), do: repl()

  def serve(%{repl?: false}) do
    IO.puts("Running with --no-repl. Ctrl-C to stop.")
    Process.sleep(:infinity)
  end

  @spec repl() :: :ok
  def repl() do
    case IO.gets("> ") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      input when is_binary(input) ->
        input
        |> String.trim()
        |> handle_command()

        repl()
    end
  end

  defp handle_command("console"), do: NervesMCP.console()
  defp handle_command("history"), do: NervesMCP.history()
  defp handle_command("exit"), do: NervesMCP.exit()
  defp handle_command("help"), do: IO.puts("Commands: console, history, exit, help")
  defp handle_command(""), do: :ok
  defp handle_command(other), do: IO.puts("Unknown command: #{other}. Type 'help' for commands.")

  @doc """
  Parse args into the application env, then start the children.

  The escript path. Its wrapper starts the application first, so any children
  already up from `config/config.exs` are replaced. `Mix.Tasks.NervesMcp`
  configures before `app.start` instead and doesn't call this.
  """
  @spec run([String.t()]) :: config()
  def run(args) do
    config = configure(args)

    start_children(config.connection, config.mcp_port)
    announce(config)

    config
  end

  @doc """
  Print the port and connection the server came up on, and how to point Claude
  Code at it.
  """
  @spec announce(config()) :: :ok
  def announce(config) do
    IO.puts(
      "NervesMCP started on port #{config.mcp_port} via #{connection_desc(config.connection)}"
    )

    maybe_print_claude_hint(config.mcp_port)
  end

  @doc """
  Parse args, merge them over `config/config.exs` and store the result in the
  application env. Starts nothing.
  """
  @spec configure([String.t()]) :: config()
  def configure(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          serial: :string,
          ssh: :string,
          port: :integer,
          speed: :integer,
          user: :string,
          ssh_port: :integer,
          pass: :string,
          no_repl: :boolean
        ],
        aliases: [
          p: :port,
          s: :speed,
          u: :user
        ]
      )

    existing_config = Application.get_env(:nerves_mcp, :connection, [])
    connection = resolve_connection(opts, positional, existing_config)

    mcp_port =
      opts
      |> Keyword.get(:port, Application.get_env(:nerves_mcp, :port, 13000))
      |> validate_mcp_port!()

    Application.put_env(:nerves_mcp, :connection, connection)
    Application.put_env(:nerves_mcp, :port, mcp_port)

    %{
      connection: connection,
      mcp_port: mcp_port,
      repl?: not Keyword.get(opts, :no_repl, false)
    }
  end

  # Bandit accepts 0 as "any free port", but then the startup banner and the
  # `claude mcp add` hint both print 0 and nobody can reach the server. Rejected
  # along with the rest of the out-of-range values.
  defp validate_mcp_port!(port) when is_integer(port) and port in 1..65_535, do: port

  defp validate_mcp_port!(port) do
    raise ArgumentError,
          "invalid MCP port #{inspect(port)}, expected an integer in 1..65535 " <>
            "(--port, or :port in config/config.exs)"
  end

  defp connection_desc(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart ->
        "serial #{Keyword.fetch!(connection, :port)} @ #{Keyword.get(connection, :speed, 115_200)}"

      :ssh ->
        "ssh #{Keyword.get(connection, :user, "root")}@#{Keyword.fetch!(connection, :host)}:#{Keyword.get(connection, :port, 22)}"
    end
  end

  defp maybe_print_claude_hint(mcp_port) do
    if System.find_executable("claude") do
      IO.puts("""

      Claude Code detected. Add this MCP server with:
        claude mcp add --transport http nerves http://localhost:#{mcp_port}/mcp
      """)
    else
      :ok
    end
  end

  defp resolve_connection(opts, positional, existing_config) do
    cond do
      # Explicit --serial flag
      Keyword.has_key?(opts, :serial) ->
        serial_config(Keyword.fetch!(opts, :serial), opts, existing_config)

      # Explicit --ssh flag
      Keyword.has_key?(opts, :ssh) ->
        ssh_config(Keyword.fetch!(opts, :ssh), opts, existing_config)

      # First positional arg matches a serial device pattern
      match?([_ | _], positional) and serial_device?(hd(positional)) ->
        serial_config(hd(positional), opts, existing_config)

      # First positional arg is treated as SSH host
      match?([_ | _], positional) ->
        ssh_config(hd(positional), opts, existing_config)

      # No args — fall back to existing config
      Keyword.has_key?(existing_config, :type) ->
        apply_overrides(existing_config, opts)

      true ->
        IO.puts("""
        Usage: nerves_mcp <device-or-host> [options]

        Examples:
          nerves_mcp /dev/ttyUSB0                   # Serial connection
          nerves_mcp /dev/ttyUSB0 --speed 9600      # Serial with custom baud rate
          nerves_mcp nerves.local                   # SSH connection
          nerves_mcp nerves.local --user root       # SSH with custom user
          nerves_mcp nerves.local --no-repl         # No stdin console
          nerves_mcp --serial /dev/ttyACM0          # Explicit serial
          nerves_mcp --ssh 192.168.1.100            # Explicit SSH

        Options:
          --port PORT        MCP server port (default: 13000)
          --speed BAUD       Serial baud rate (default: 115200)
          --user USER        SSH user (default: root)
          --ssh-port PORT    SSH port (default: 22)
          --pass PASSWORD    SSH password (requires sshpass; not for high-security use)
          --no-repl          Don't read stdin, block instead (for background runs)

        Connection can also be configured in config/config.exs.
        CLI arguments override config values.
        """)

        System.halt(1)
    end
  end

  defp serial_config(device, opts, existing_config) do
    base =
      if Keyword.get(existing_config, :type) == :uart do
        existing_config
      else
        [type: :uart, speed: 115_200]
      end

    base
    |> Keyword.put(:port, device)
    |> apply_overrides(opts)
  end

  defp ssh_config(host, opts, existing_config) do
    base =
      if Keyword.get(existing_config, :type) == :ssh do
        existing_config
      else
        [type: :ssh, user: "root", port: 22]
      end

    base
    |> Keyword.put(:host, host)
    |> apply_overrides(opts)
  end

  defp apply_overrides(config, opts) do
    config
    |> maybe_put(:speed, Keyword.get(opts, :speed))
    |> maybe_put(:user, Keyword.get(opts, :user))
    |> maybe_put(:port, Keyword.get(opts, :ssh_port))
    |> maybe_put(:pass, Keyword.get(opts, :pass))
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)

  defp serial_device?(path) do
    Enum.any?(@serial_patterns, &String.starts_with?(path, &1))
  end

  defp start_children(connection, mcp_port) do
    connection_child =
      case Keyword.fetch!(connection, :type) do
        :uart -> NervesMCP.Connection.UART
        :ssh -> NervesMCP.Connection.SSH
      end

    stop_children()

    children = [
      NervesMCP.History,
      {Bandit, plug: NervesMCP.Router, port: mcp_port, ip: :loopback},
      connection_child,
      NervesMCP.DeviceProbe
    ]

    for child <- children do
      Supervisor.start_child(NervesMCP.Supervisor, child)
    end
  end

  # `NervesMCP.Application` already started this set from config/config.exs when
  # the config names a `:type`, on the config port and against the config host.
  # Bandit's child id is a fresh reference every time, so a second start_child
  # leaves two listeners rather than colliding.
  defp stop_children() do
    for {id, _pid, _type, _modules} <- Supervisor.which_children(NervesMCP.Supervisor) do
      Supervisor.terminate_child(NervesMCP.Supervisor, id)
      Supervisor.delete_child(NervesMCP.Supervisor, id)
    end
  end
end
