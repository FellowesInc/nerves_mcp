defmodule NervesMCP.Tools.Device do
  @moduledoc """
  Connection dispatch for the device tools, and the one device-down check.

  The tool list no longer changes when the device goes away, so every call that
  needs the device comes through here and gets the same error while the probe
  reports `:down` or `:unknown`. A client that lost the device after a reboot
  sees the error and can call `is_device_up`, instead of watching the tool
  disappear from a list it may never refetch. When the SSH connection knows why
  it can't reach the device, the error says that instead.

  Every function takes the device name, which a tool gets from `with_device/2`.
  """

  alias NervesMCP.Connection.SSH
  alias NervesMCP.DeviceProbe
  alias NervesMCP.Devices

  @down_modes [:down, :unknown]

  @type result() :: {:ok, String.t()} | {:error, String.t()}

  @doc "The `device` argument every tool takes, for its input schema."
  @spec schema() :: map()
  def schema() do
    %{
      type: :string,
      description: "Which device, by name. Optional when only one device is configured."
    }
  end

  @doc """
  Run `fun` with the device the call's `device` argument names, or the only one
  configured. An unknown name, or none with several configured, is a tool error.
  """
  @spec with_device(map(), (Devices.name() -> term())) :: term()
  def with_device(args, fun) do
    case Devices.resolve(args["device"]) do
      {:ok, device} -> fun.(device)
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end

  @spec eval(Devices.name(), String.t(), non_neg_integer()) :: result()
  def eval(device, code, timeout), do: run(device, :eval, [code, timeout])

  @spec eval_output(Devices.name(), String.t(), non_neg_integer()) :: result()
  def eval_output(device, code, timeout), do: run(device, :eval_output, [code, timeout])

  @spec shell_eval(Devices.name(), String.t(), non_neg_integer()) :: result()
  def shell_eval(device, command, timeout), do: run(device, :shell_eval, [command, timeout])

  @spec shell_eval_output(Devices.name(), String.t(), non_neg_integer()) :: result()
  def shell_eval_output(device, command, timeout),
    do: run(device, :shell_eval_output, [command, timeout])

  @doc """
  Evaluate with no device-down check, for the tools that poll a device back up.
  """
  @spec eval_unchecked(Devices.name(), String.t(), non_neg_integer()) :: result()
  def eval_unchecked(device, code, timeout) do
    with {:ok, module} <- Devices.module(device), do: call(module, :eval, [device, code, timeout])
  end

  @doc "The device-down check the tools share. `:ok` when the device can be reached."
  @spec ensure_up(Devices.name()) :: :ok | {:error, String.t()}
  def ensure_up(device) do
    mode = DeviceProbe.mode(device)

    if mode in @down_modes do
      {:error, "Device is down (mode: #{mode}). " <> next_step(connection_status(device))}
    else
      :ok
    end
  end

  @doc "Give the SSH connection an address for a device name that won't resolve."
  @spec set_address(Devices.name(), String.t()) :: result()
  def set_address(device, address) do
    case Devices.module(device) do
      {:ok, SSH} -> SSH.set_address(device, address)
      {:ok, _uart} -> {:error, "set_device_address only applies to an SSH connection"}
      error -> error
    end
  catch
    :exit, reason -> {:error, "Device connection error: #{inspect(reason)}"}
  end

  @doc "The SSH connection's status, or `nil` when there is no SSH connection."
  @spec connection_status(Devices.name()) :: SSH.status() | nil
  def connection_status(device) do
    case Devices.module(device) do
      {:ok, SSH} -> SSH.status(device)
      _uart_or_unknown -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp next_step(%{reason: reason}) when is_binary(reason), do: reason
  defp next_step(_nothing_to_add), do: "Call is_device_up to wait for it."

  defp run(device, fun, args) do
    with :ok <- ensure_up(device),
         {:ok, module} <- Devices.module(device) do
      call(module, fun, [device | args])
    end
  end

  defp call(module, fun, args) do
    apply(module, fun, args)
  catch
    :exit, {:noproc, _} ->
      {:error, "Device connection not available (process not running)"}

    :exit, reason ->
      {:error, "Device connection error: #{inspect(reason)}"}
  end
end
