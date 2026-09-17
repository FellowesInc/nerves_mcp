defmodule NervesMCP.Tools.ShellEval do
  @moduledoc """
  Run a raw shell command on the connected device.

  Exposed (under the `device_eval` name) when the device probe detects a serial
  connection that responds but does not run Elixir. Mirrors the density
  `device_mcp` behaviour: the command is wrapped in `echo` markers and the
  output between them is returned.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.Tools.Device

  @impl EMCP.Tool
  def name(), do: "device_eval"

  @impl EMCP.Tool
  def description(),
    do:
      "Run a raw shell command on the connected device and return the output (device is not running Elixir)"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        command: %{type: :string, description: "Shell command to run on the device"},
        timeout: %{type: :integer, description: "Timeout in milliseconds (default: 15000)"}
      },
      required: [:command]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    command = args["command"]
    timeout = args["timeout"] || 15000

    case Device.shell_eval(command, timeout) do
      {:ok, output} -> EMCP.Tool.response([%{"type" => "text", "text" => output}])
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end
end
