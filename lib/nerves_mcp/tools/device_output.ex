defmodule NervesMCP.Tools.DeviceOutput do
  @moduledoc """
  Read what the device printed into the session.

  `device_eval` only returns what its own expression returned, so anything a
  spawned process, a GenServer or the logger prints afterwards is invisible to
  it. That output is still buffered by `NervesMCP.History`, and this is how to
  read it.
  """

  @behaviour EMCP.Tool

  alias NervesMCP.History

  @impl EMCP.Tool
  def name(), do: "device_output"

  @impl EMCP.Tool
  def description(),
    do:
      "Read output the device printed into the session, including from processes spawned by an earlier device_eval. Pass the cursor from the previous call to read only what is new."

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        cursor: %{
          type: :integer,
          description:
            "Cursor from a previous device_output call. Omit it to read everything still buffered."
        }
      },
      required: []
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    case read(args["cursor"]) do
      {:ok, output, cursor} ->
        EMCP.Tool.response([%{"type" => "text", "text" => text(output, cursor)}])

      {:error, reason} ->
        EMCP.Tool.error(reason)
    end
  end

  defp read(cursor) do
    {output, next_cursor} = History.since(cursor)
    {:ok, output, next_cursor}
  catch
    :exit, {:noproc, _} -> {:error, "Device output history is not running"}
    :exit, reason -> {:error, "Device output history error: #{inspect(reason)}"}
  end

  defp text("", cursor), do: "No device output since the last cursor.\n\ncursor: #{cursor}"
  defp text(output, cursor), do: "#{output}\n\ncursor: #{cursor}"
end
