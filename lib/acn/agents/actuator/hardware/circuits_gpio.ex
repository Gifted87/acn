defmodule ACN.Actuator.Hardware.CircuitsGPIO do
  @behaviour ACN.Actuator.Hardware.Adapter
  require Logger

  # Only compile this on systems where Circuits.GPIO is available/safe
  # Or rely on the fact it's a NIF that might fail to load on non-Linux.
  # But the code itself is just Elixir.

  @impl true
  def gpio_write(pin, state) do
    val = if state == :high, do: 1, else: 0
    
    # Stateless open-write-close pattern for simplicity
    with {:ok, gpio} <- Circuits.GPIO.open(pin, :output),
         :ok <- Circuits.GPIO.write(gpio, val) do
      Circuits.GPIO.close(gpio)
      :ok
    else
      {:error, reason} ->
        Logger.error("GPIO Write Error (Pin #{pin}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def gpio_read(pin) do
    with {:ok, gpio} <- Circuits.GPIO.open(pin, :input),
         {:ok, val} <- Circuits.GPIO.read(gpio) do
      Circuits.GPIO.close(gpio)
      {:ok, val == 1}
    else
      {:error, reason} ->
        Logger.error("GPIO Read Error (Pin #{pin}): #{inspect(reason)}")
        {:error, reason}
    end
  end
end
