defmodule NervesMCP.Tools.Device do
  @moduledoc """
  Connection dispatch for the device tools, and the one device-down check.

  The tool list no longer changes when the device goes away, so every call that
  needs the device comes through here and gets the same error while the probe
  reports `:down` or `:unknown`. A client that lost the device after a reboot
  sees the error and can call `is_device_up`, instead of watching the tool
  disappear from a list it may never refetch.
  """

  alias NervesMCP.Connection.SSH
  alias NervesMCP.Connection.UART
  alias NervesMCP.DeviceProbe

  @down_modes [:down, :unknown]

  @type result() :: {:ok, String.t()} | {:error, String.t()}

  @spec eval(String.t(), non_neg_integer()) :: result()
  def eval(code, timeout), do: run(:eval, [code, timeout])

  @spec eval_output(String.t(), non_neg_integer()) :: result()
  def eval_output(code, timeout), do: run(:eval_output, [code, timeout])

  @spec shell_eval(String.t(), non_neg_integer()) :: result()
  def shell_eval(command, timeout), do: run(:shell_eval, [command, timeout])

  @spec shell_eval_output(String.t(), non_neg_integer()) :: result()
  def shell_eval_output(command, timeout), do: run(:shell_eval_output, [command, timeout])

  @doc "The device-down check the tools share. `:ok` when the device can be reached."
  @spec ensure_up() :: :ok | {:error, String.t()}
  def ensure_up() do
    mode = DeviceProbe.mode()

    if mode in @down_modes do
      {:error, "Device is down (mode: #{mode}). Call is_device_up to wait for it."}
    else
      :ok
    end
  end

  defp run(fun, args) do
    with :ok <- ensure_up(),
         {:ok, module} <- connection() do
      try do
        apply(module, fun, args)
      catch
        :exit, {:noproc, _} ->
          {:error, "Device connection not available (process not running)"}

        :exit, reason ->
          {:error, "Device connection error: #{inspect(reason)}"}
      end
    end
  end

  defp connection() do
    config = Application.get_env(:nerves_mcp, :connection, [])

    case Keyword.get(config, :type, :uart) do
      :uart -> {:ok, UART}
      :ssh -> {:ok, SSH}
      other -> {:error, "Unknown connection type: #{inspect(other)}"}
    end
  end
end
