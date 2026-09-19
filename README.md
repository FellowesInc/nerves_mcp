# NervesMCP

An MCP (Model Context Protocol) server for interacting with Nerves devices. Enables AI assistants to evaluate Elixir code on embedded devices connected via UART or SSH.

## Installation

Add to your dependencies:

```elixir
def deps do
  [
    {:nerves_mcp, "~> 0.1.0"}
  ]
end
```

## Usage

NervesMCP can be run as a Mix task or as a standalone escript. The first argument is either a serial device path or an SSH host — NervesMCP auto-detects which based on the path.

### Mix task

```bash
# Serial — auto-detected from /dev/tty* path
mix nerves_mcp /dev/ttyUSB0
mix nerves_mcp /dev/ttyUSB0 --speed 9600

# SSH — anything that isn't a serial path is treated as a host
mix nerves_mcp nerves.local
mix nerves_mcp nerves.local --user root --ssh-port 2222

# An IP works as the host too, e.g. on a network where mDNS doesn't resolve
mix nerves_mcp 192.168.1.100
```

### Escript

Build the escript and run it directly:

```bash
mix escript.build
./nerves_mcp /dev/ttyUSB0
./nerves_mcp nerves.local --user exnvr --port 4000
```

### Options

| Flag         | Description                                               | Default  |
|--------------|-----------------------------------------------------------|----------|
| `--port`     | MCP server HTTP port                                      | `13000`  |
| `--speed`    | Serial baud rate                                          | `115200` |
| `--user`     | SSH username                                              | `root`   |
| `--ssh-port` | SSH port                                                  | `22`     |
| `--pass`     | SSH password (needs `sshpass`; not for high-security use) |          |
| `--serial`   | Force serial mode (pass device)                           |          |
| `--ssh`      | Force SSH mode (pass host)                                |          |
| `--no-repl`  | Skip the stdin console and block instead                  |          |

Short aliases: `-p` (port), `-s` (speed), `-u` (user).

### `--no-repl`

By default the foreground is the stdin console, which exits on EOF and takes the
server with it. `--no-repl` blocks instead, so the server survives a closed
stdin and can run from a background shell or under a process supervisor:

```bash
nohup ./nerves_mcp nerves.local --no-repl > nerves_mcp.log 2>&1 &
```

Ctrl-C still stops it. Under the escript that exits straight away; under `mix`
it opens the Erlang break menu, where `a` aborts.

### Configuration file

Connection settings can also be defined in `config/config.exs`. CLI arguments override config values.

```elixir
# Serial
config :nerves_mcp, :port, 13000
config :nerves_mcp, :connection,
  type: :uart,
  port: "/dev/ttyUSB0",
  speed: 115_200

# Or SSH
config :nerves_mcp, :connection,
  type: :ssh,
  host: "nerves.local",
  user: "root",
  port: 22
```

With config in place, you can start without any arguments:

```bash
mix nerves_mcp
```

Or override specific values:

```bash
mix nerves_mcp --speed 9600    # use config but change baud rate
mix nerves_mcp other.local     # switch to a different host entirely
```

### Auto-detection

If the first argument starts with `/dev/tty`, `/dev/cu.`, or `/dev/serial`, it is treated as a serial device. Otherwise it is treated as an SSH host. Use `--serial` or `--ssh` to be explicit:

```bash
mix nerves_mcp --serial /dev/ttyACM0
mix nerves_mcp --ssh 192.168.1.100
```

### Connecting to the MCP server

Once running, the MCP server is available at:

```
http://localhost:13000/mcp
```

Or whatever port you specified with `--port`.

The HTTP server binds to loopback only. The `/mcp` endpoint has no
authentication and `device_eval` runs code on the connected device, so it is
not something to expose on a network.

## MCP Tools

### device_eval

Evaluates Elixir code on the device and returns the expression's return value.

### device_eval_output

Evaluates Elixir code and captures IO output (what the code prints via `IO.puts`, `IO.write`, etc.) in addition to the return value.

### device_output

Returns session output buffered since a cursor you pass in, and the new cursor. For reading output from something spawned on the device that keeps printing after `device_eval` returned.

### grep_ring_logger

Filters the device's `RingLogger` buffer by a substring or regex pattern. Optional `tail` returns only the last N matches.

### grep_dmesg

Filters the device's `dmesg` (kernel ring buffer) by a substring or regex pattern. Optional `tail` returns only the last N matches.

### is_device_up

Polls the device for its firmware UUID until it answers or the timeout runs out. Use it to wait out a reboot. `timeout` defaults to 60000 ms.

### is_device_updated_to

Same poll as `is_device_up`, but against an `expected_uuid`. Errors if the device comes back on a different UUID, which is how a reverted firmware update shows up.

### device_status

Reports what the probe currently detects on the other end of the connection (`nerves`, `elixir`, `shell`, `down` or `unknown`), and which tools that state offers. Pass `refresh: true` to probe now instead of reading the cached result. Over SSH it also shows what the connection is trying, the device's cached address, and why it can't reach the device when there is something to do about it.

### set_device_address

Gives the SSH connection an IP `address` for a device whose name won't resolve. The address has to pass the hostname check below before anything runs on it, and is then cached. The configured name stays primary.

### When the device is down

The tool list doesn't shrink. Tools that need a live device stay listed and
return an error pointing the caller at `is_device_up`, so a client that fetched
the list before a reboot doesn't lose the tools it needs to wait for the device
to come back.

## Learned device address

After a reboot a device's mDNS name, e.g. `nerves-1234.local`, can stay
unresolvable for minutes while its IP already answers. So over SSH:

1. **Learned while mDNS works.** Each time the name answers, the address it
   resolves to on this machine is cached under the device's hostname, the first
   label of the name (`nerves-1234`).
2. **Used and verified after a reboot.** When the name stops answering,
   attempts alternate between the name and the cached address, backing off as
   usual. A connection on the address runs nothing until the device reports its
   hostname. A match is used. Anything else means DHCP gave the address to
   another device, so the connection closes and the address is dropped.
3. **Asks when there's nothing.** With no usable address, the down error,
   `is_device_up`'s timeout and `device_status` say so and tell the agent to ask
   the user for the device's IP and call `set_device_address`.

A host given as an IP address learns and checks nothing.

The cache is per developer, since the addresses belong to the developer's
network. It lives in the user cache directory,
`~/Library/Caches/nerves_mcp/addresses.term` on macOS and
`~/.cache/nerves_mcp/addresses.term` on Linux, one
`{<<"hostname">>, <<"address">>}.` term per line. Deleting it is safe. To put
it somewhere else:

```elixir
config :nerves_mcp, :address_cache_dir, "/path/to/dir"
```

## Interactive Console

From IEx, you can open an interactive console to the device:

```elixir
iex> console()
Connected to device console. Commands: #quit, #history
---
```

This lets you interact directly with the device's IEx shell. Commands:

- `#quit` - Exit the console and return to local IEx
- `#history` - Display buffered output history

## Output History

Device output is stored in a circular buffer, even when no console is attached. This includes output from MCP tool calls.

```elixir
iex> history()
```

Or use `#history` while in the console.

## License

Apache-2.0
