import Config

# MCP server port (CLI --port overrides this)
# config :nerves_mcp, :port, 13000

# UART connection (CLI args override these)
# config :nerves_mcp, :connection,
#   type: :uart,
#   port: "/dev/ttyUSB0",
#   speed: 115_200

# SSH connection (CLI args override these)
# config :nerves_mcp, :connection,
#   type: :ssh,
#   host: "nerves.local",
#   user: "root",
#   port: 22

# Where the SSH connection caches device addresses (default: the user cache
# directory, e.g. ~/Library/Caches/nerves_mcp on macOS)
# config :nerves_mcp, :address_cache_dir, "/path/to/dir"

config :bun, :version, "1.3.0"
