defmodule ACN.Core.Redactor do
  @moduledoc """
  Sanitizes logs to remove PII and API Secrets.
  """
  
  @replacement "[REDACTED]"
  
  def sanitize(data) when is_map(data) do
    Enum.into(data, %{}, fn {k, v} -> 
      if sensitive_key?(k) do
        {k, @replacement}
      else
        {k, sanitize(v)}
      end
    end)
  end
  
  def sanitize(list) when is_list(list) do
    Enum.map(list, &sanitize/1)
  end
  
  def sanitize(val), do: val

  defp sensitive_key?(k) do
    k_str = to_string(k) |> String.downcase()
    String.contains?(k_str, "key") or 
    String.contains?(k_str, "token") or
    String.contains?(k_str, "secret") or 
    String.contains?(k_str, "auth") or
    String.contains?(k_str, "authorization")
  end
end
