defmodule ACN.Core.ProfileLoader do
  require Logger

  @response_style_instruction """

  RESPONSE STYLE:
  Be concise and fast. Give the direct answer or required tool call, and omit
  preambles, repetition, and explanations that do not help complete the task.
  Include details only when needed for correctness or explicitly requested.
  Do not skip required work, checks, or evidence to be brief.
  """

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
        # Convert vars to atom keys for bindings
        atom_vars = Map.new(vars, fn {k, v} -> {String.to_atom(to_string(k)), v} end)

        # We bind variables as locals AND as 'assigns' to support @var syntax
        # We also add an 'indent' helper
        indent_fn = fn str, spaces ->
          prefix = String.duplicate(" ", spaces)

          # Safely coerce any type (map, struct, list, nil, etc.) to a printable string.
          # Using inspect/1 for non-string types avoids Protocol.UndefinedError and
          # guarantees the output is always a valid string.
          safe_str =
            cond do
              is_binary(str) -> str
              is_nil(str) -> ""
              is_map(str) or is_list(str) -> inspect(str, pretty: true, limit: :infinity)
              true -> to_string(str)
            end

          # Indent EVERY line (including line 0) so that injected content never
          # drops below the YAML block scalar's base indentation level and
          # accidentally terminates the scalar early.
          safe_str
          |> String.split("\n")
          |> Enum.map_join("\n", fn line -> "#{prefix}#{line}" end)
        end

        bindings = Map.to_list(atom_vars) ++ [assigns: atom_vars, indent: indent_fn]

        rendered_yaml = EEx.eval_string(raw_yaml, bindings)

        # 3. Parse YAML
        case YamlElixir.read_from_string(rendered_yaml) do
          {:ok, map} ->
            map =
              case Map.get(map, "system_prompt") do
                prompt when is_binary(prompt) ->
                  Map.put(map, "system_prompt", prompt <> @response_style_instruction)

                _ ->
                  map
              end

            {:ok, map}

          {:error, reason} ->
            {:error, {:parse_error, reason}}
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
