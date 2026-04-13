defmodule ACNWeb.ErrorView do
  def render(template, _assigns) do
    # Simple string response to avoid HTML engine dependency
    "#{template} - Not Found"
  end
end
