defmodule ACN.Observability.ShadowWriter do
  @moduledoc """
  HSG Phase 4 — The Spatial Introspection Layer.

  A stateless module that flushes telemetry payloads to `.shadow` directories
  mirroring the actual workspace structure. Called asynchronously from the Panopticon.
  """
  alias ACN.Observability.MicroDBC

  @doc """
  Takes a `MicroDBC` and writes its vectors to physical files in the `.shadow` directory.
  """
  def write(%MicroDBC{} = dbc) do
    # 1. Determine shadow root path
    # E.g., mat_path: "root.auth.db" -> base_dir: "root/auth/db"
    # The actual implementation plan says: replace `.` with `/` and prepend `root/.shadow/`
    workspace_root = Application.get_env(:acn, :hsg)[:shadow_root] || "tmp/acn_workspaces"
    workspace_root = Path.expand(workspace_root)
    
    # mat_path might be "root.auth.db". We want the structure to be "root/.shadow/auth/db"
    # To do this safely:
    parts = String.split(dbc.mat_path || "root", ".")
    [root_node | rest_path] = parts
    
    shadow_dir = 
      [workspace_root, root_node, ".shadow"] ++ rest_path
      |> Path.join()

    require Logger
    Logger.info("HSG ShadowWriter: Executing for event #{dbc.event_id} at #{shadow_dir}")

    # Ensure dir exists before any writes
    File.mkdir_p!(shadow_dir)

    # 2. Write Cognitive Vector
    if dbc.cognitive do
      cog_file = Path.join(shadow_dir, "cognitive.jsonl")
      entry = %{
        timestamp: dbc.timestamp,
        event_id: dbc.event_id,
        model: dbc.cognitive[:model],
        temperature: dbc.cognitive[:temperature],
        token_count_in: dbc.cognitive[:token_count_in],
        token_count_out: dbc.cognitive[:token_count_out],
        result_accepted: dbc.cognitive[:result_accepted],
        # The prompt/response text is assumed to be in Process Dictionary during harvest phase?
        # ACTUALLY: The design brief says MicroDBC.cognitive doesn't hold the raw prompt string 
        # because Mnesia shouldn't store it. It says "The raw prompt itself is written to the .shadow overlay; Mnesia only stores the hash".
        # This implies Emitter MUST pass the raw string to Panopticon, which passes it to ShadowWriter,
        # but strips it before passing to Persistence. Let's assume `dbc.cognitive[:raw_prompt]` exists 
        # in the MicroDBC struct traversing RAM, but is ignored by `Persistence.persist`.
        prompt: dbc.cognitive[:raw_prompt],
        response: dbc.cognitive[:raw_response]
      }
      append_jsonl(cog_file, entry)
    end

    # 3. Write Physical Vector
    if dbc.physical do
      phys_file = Path.join(shadow_dir, "physical.patch")
      diff_text = dbc.physical[:unified_diff] || "No diff provided."
      
      content = """
      --- event_id: #{dbc.event_id}
      --- timestamp: #{dbc.timestamp}
      --- file: #{dbc.physical[:file_path]}
      #{diff_text}

      """
      append_raw(phys_file, content)
    end

    # 4. Write Security Vector
    if dbc.security do
      sec_file = Path.join(shadow_dir, "security.audit")
      entry = %{
        timestamp: dbc.timestamp,
        event_id: dbc.event_id,
        jwt_jti: dbc.security[:jwt_jti],
        required_scopes: dbc.security[:required_scopes],
        granted_scopes: dbc.security[:granted_scopes],
        target_path: dbc.security[:target_path],
        outcome: dbc.security[:outcome]
      }
      append_jsonl(sec_file, entry)
    end

    # 5. Write Autonomic Vector (Stress / LiveWire)
    if dbc.autonomic do
      auto_file = Path.join(shadow_dir, "autonomic.log")
      entry = %{
        timestamp: dbc.timestamp,
        event_id: dbc.event_id,
        stress_level: dbc.autonomic[:stress_level],
        rejection_count: dbc.autonomic[:rejection_count]
      }
      append_jsonl(auto_file, entry)
    end

    :ok
  end

  # --- Private Helpers ---

  defp append_jsonl(path, map) do
    # Encode to JSON and add newline
    json = Jason.encode!(map) <> "\n"
    append_raw(path, json)
  end

  defp append_raw(path, iodata) do
    # Uses Erlang `:file.open/2` with `[:raw, :append]` for POSIX atomic append guarantees
    case :file.open(String.to_charlist(path), [:raw, :append]) do
      {:ok, io_device} ->
        :file.write(io_device, iodata)
        :file.close(io_device)
      {:error, reason} ->
        require Logger
        Logger.error("HSG ShadowWriter: Failed to append to #{path}: #{inspect(reason)}")
    end
  end
end
