defmodule ACN.Agents.Actuator.ContractVerifier do
  @moduledoc """
  Phase 3: Artifact Contract Verifier.

  Verifies that a leaf node has produced all the files it was contracted to create
  (as declared in the `file_manifest` from the Blueprint phase).

  Called by the Controller before emitting a success signal, ensuring that nodes
  cannot "complete" without having physically created their committed outputs.
  """

  require Logger

  @doc """
  Verifies that all files in `file_manifest` exist within `working_path`.

  ## Parameters
  - `working_path`: The absolute directory the node was bound to.
  - `file_manifest`: List of relative file paths the node was contracted to produce.

  ## Returns
  - `:ok` — All contracted files are present.
  - `{:error, missing_files}` — One or more files are missing. Returns the list.
  - `:skip` — No manifest was provided; verification is skipped (legacy compatibility).
  """
  @spec verify(String.t(), list(String.t())) :: :ok | {:error, list(String.t())} | :skip
  def verify(_working_path, nil), do: :skip
  def verify(_working_path, []), do: :skip
  def verify(working_path, file_manifest) when is_list(file_manifest) do
    missing =
      file_manifest
      |> Enum.reject(fn relative_path ->
        abs_path = Path.join(working_path, relative_path)
        File.exists?(abs_path)
      end)

    if Enum.empty?(missing) do
      Logger.info("ContractVerifier: All #{length(file_manifest)} contracted files verified in #{working_path}.")
      :ok
    else
      Logger.error("""
      ContractVerifier: CONTRACT VIOLATION in #{working_path}.
      Node declared it would produce #{length(file_manifest)} files but #{length(missing)} are MISSING:
      #{Enum.map_join(missing, "\n", fn f -> "  ✗ #{Path.join(working_path, f)}" end)}
      """)
      {:error, missing}
    end
  end

  @doc """
  Builds a feedback string for the AI agent describing which files are missing.
  Used to inject into a retry prompt so the agent knows exactly what to produce.
  """
  @spec build_feedback(String.t(), list(String.t())) :: String.t()
  def build_feedback(working_path, missing_files) do
    file_list = Enum.map_join(missing_files, "\n", fn f -> "  - #{Path.join(working_path, f)}" end)
    """
    [CONTRACT VIOLATION]: Your task is not complete. The following files were declared in your blueprint \
    but were NOT created:
    #{file_list}

    You MUST create ALL missing files before your task can be considered complete. \
    Use the write_to_file tool for each missing file.
    """
  end
end
