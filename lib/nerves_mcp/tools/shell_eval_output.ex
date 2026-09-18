defmodule NervesMCP.Tools.ShellEvalOutput do
  @moduledoc """
  Run a raw shell command on the connected device, capturing stdout, stderr,
  and the exit code.

  Exposed (under the `device_eval_output` name) when the device probe detects a
  serial connection that responds but does not run Elixir.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.Tools.Device

  @impl EMCP.Tool
  def name(), do: "device_eval_output"

  @impl EMCP.Tool
  def description(),
    do:
      "Run a raw shell command on the connected device and capture stdout, stderr, and exit code (device is not running Elixir)"

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

    case Device.shell_eval_output(command, timeout) do
      {:ok, output} -> EMCP.Tool.response([%{"type" => "text", "text" => output}])
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end
end
