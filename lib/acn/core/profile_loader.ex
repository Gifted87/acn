defmodule ACN.Core.ProfileLoader do
  require Logger

  @doc """
  Loads and parses a YAML profile, supporting EEx variable injection.
  Args:
  - profile_name: String (filename without extension)
  - vars: Map of variables to inject into the template (default: %{})
  """
  def load(profile_name, vars \\ %{}) do
    # Resolve Path
    path = Application.app_dir(:acn, "priv/profiles/#{profile_name}.yaml")

    if File.exists?(path) do
      try do
        # 1. Read Raw String
        raw_yaml = File.read!(path)

        # 2. Evaluate EEx (Safety: binding vars)
        # We explicitly bind variables as bindings (local variables)
        bindings = Enum.map(vars, fn {k, v} -> {String.to_atom(to_string(k)), v} end)
        rendered_yaml = EEx.eval_string(raw_yaml, bindings)

        # 3. Parse YAML
        case YamlElixir.read_from_string(rendered_yaml) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:parse_error, reason}}
        end
      rescue
        e ->
          Logger.error("Failed to load profile #{profile_name}: #{inspect(e)}")
          {:error, {:render_error, e}}
      end
    else
      {:error, :profile_not_found}
    end
  end
end
