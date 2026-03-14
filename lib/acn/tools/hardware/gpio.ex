defmodule ACN.Tools.Hardware.GPIO do
  @behaviour ACN.Tools.ToolBehaviour

  def definition do
    %{
      name: "hardware_gpio",
      description: "Control physical GPIO pins.",
      parameters: %{
        type: "object",
        properties: %{
          pin: %{type: "integer"},
          state: %{type: "string", enum: ["high", "low", "input"]}
        },
        required: ["pin", "state"]
      }
    }
  end

  # Safe Pin List logic should also check here or in Actuator
  def execute(_args, _env), do: {:error, :use_actuator_directly}
end
