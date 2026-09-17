# Changelog

All notable changes to this fork are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `--no-repl` starts the server without the stdin console and blocks instead, so
  it survives stdin EOF and can run from a background shell or under a process
  supervisor.
- `--fallback-host HOST`, stored as `:fallback_host` in the `:connection` config.
  The SSH connection alternates to it when ssh can't resolve the primary host,
  which covers an mDNS name that stops resolving while the IP still works.
- `device_output` returns session output buffered since a cursor, for reading
  from a process spawned on the device that keeps printing after `device_eval`
  returned.
- A `mix check` alias that runs `hex.audit`, `compile --warnings-as-errors`,
  `format --check-formatted`, `credo`, `deps.unlock --check-unused`, `dialyzer`
  and `spellweaver.check`, plus a `.cspell.json` that keeps cspell out of
  `_build` and `deps`.
- A test harness. `test/support/ssh_daemon.ex` runs an Erlang `:ssh` daemon with
  an IEx shell on loopback, the same stack `nerves_ssh` runs on a device, so the
  eval protocol is tested against real echo and line editing.
- Tests for CLI option parsing into the application env.
- A README section for every tool the server exposes, the `--pass`,
  `--fallback-host` and `--no-repl` flags, and the loopback bind.

### Changed

- The MCP HTTP server binds to `ip: :loopback`. Bandit listened on every
  interface and `/mcp` has no authentication, so anyone on the same network
  could run code on the connected device through `device_eval`.
- Tools that need a live device stay listed when the device is down and return
  an error pointing at `is_device_up`, instead of disappearing from the tool
  list.
- Dependencies with advisories are bumped: bandit 1.12.5, mint 1.10.0, req
  0.7.4, hpax 1.0.4, plug 1.20.3, thousand_island 1.5.0. `mix hex.audit` is
  clean.
- credo 1.7.19, which runs on Elixir 1.20 where 1.7.16 crashed. The 108 strict
  findings are fixed in the code, not in `.credo.exs`.
- `spellweaver.check` runs last in the check alias. It ends in `System.halt`, so
  anything after it never ran.

### Fixed

- `mix nerves_mcp` no longer ignores its own arguments when
  `config/config.exs` names a `:connection`. `app.start` ran first and brought
  up Bandit and the connection on the config port and host, then the CLI started
  a second set. Bandit's child id is a fresh reference every time, so both
  listeners survived. The task now runs `app.config`, parses the args into the
  application env, and starts after that. The escript, whose wrapper starts the
  application before `main/1` can parse anything, stops the config-started
  children before starting its own.
- Eval payload handling in the SSH connection.
- `grep_ring_logger` handles the map entries `RingLogger.get/1` returns.
- Elixir 1.20 warnings that failed `compile --warnings-as-errors`: `split_utf8/1`
  and `trailing_incomplete_bytes/2` pin the size variables in their binary
  matches.
- The unreachable catch-all in `DeviceProbe.classify/1`, which dialyzer reported
  as `pattern_match_cov` once `probe/1` had a spec in both connection modules.

## v0.1.0

Forked from [lawik/nerves_mcp](https://github.com/lawik/nerves_mcp).
