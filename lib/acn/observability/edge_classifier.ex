defmodule ACN.Observability.EdgeClassifier do
  @moduledoc """
  HSG Phase 2 — Edge Classifier.

  Determines the semantic meaning of an edge in the Panopticon graph based
  on the Phase transition delta found in a MicroDBC.
  """

  alias ACN.Observability.MicroDBC

  @doc """
  Takes a `MicroDBC` and returns a map describing the edge color/type.
  """
  @spec classify(MicroDBC.t()) :: map()
  def classify(%MicroDBC{phase_from: from, phase_to: to} = dbc) do
    type =
      cond do
        from == :legislating and to == :architecting -> :planning_complete
        from == :architecting and to == :execution -> :execution_start
        from == :architecting and to == :delegation -> :task_delegation
        from == :execution and to == :writing -> :disk_io
        from == :execution and to == :completed -> :success
        to == :failed -> :failure
        to == :frozen -> :locked
        to == :livewire_freeze -> :critical_panic
        true -> :state_transition
      end

    %{
      type: type,
      from: from,
      to: to,
      weight: calculate_weight(type, dbc)
    }
  end

  # Lower weight = faster traversal for shortest-path routing
  defp calculate_weight(:success, _), do: 1
  defp calculate_weight(:failure, _), do: 99
  defp calculate_weight(:critical_panic, _), do: 999
  defp calculate_weight(_, _), do: 10
end
