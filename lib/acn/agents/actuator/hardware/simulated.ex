defmodule ACN.Actuator.Hardware.Simulated do
  @behaviour ACN.Actuator.Hardware.Adapter
  require Logger

  def gpio_write(pin, state) do
     Logger.info("[HARDWARE SIMULATION] GPIO Pin #{pin} set to #{inspect(state)}")
     :ok
  end

  def gpio_read(pin) do
     Logger.info("[HARDWARE SIMULATION] GPIO Pin #{pin} read.")
     # Simulate random input or fixed
     {:ok, false}
  end
end
