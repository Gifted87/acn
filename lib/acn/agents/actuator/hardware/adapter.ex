defmodule ACN.Actuator.Hardware.Adapter do
  @callback gpio_write(pin :: integer(), state :: :high | :low) :: :ok | {:error, term()}
  @callback gpio_read(pin :: integer()) :: {:ok, boolean()} | {:error, term()}
end
