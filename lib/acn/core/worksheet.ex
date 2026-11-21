defmodule ACN.Core.Worksheet do
  @moduledoc """
  Formalizes the Agent's Memory/Workspace.
  Consists of typed Slots containing artifacts (code, plans, text).
  """

  defmodule Slot do
    @derive {Jason.Encoder, only: [:content, :type, :hash, :timestamp]}
    @type t :: %__MODULE__{
            content: any(),
            # :code | :plan | :text | :rule
            type: atom(),
            hash: String.t(),
            timestamp: integer()
          }
    defstruct [:content, :type, :hash, :timestamp]

    def new(content, type) do
      %__MODULE__{
        content: content,
        type: type,
        hash: :crypto.hash(:sha256, inspect(content, limit: :infinity)) |> Base.encode16(),
        timestamp: System.system_time(:second)
      }
    end
  end

  @type t :: %__MODULE__{
          slots: %{String.t() => Slot.t()}
        }
  defstruct slots: %{}

  @dbc_fields ~w(id artifact_hash fact_text acms_node_id author_id verifier_id validation_proof cost_metrics constituents timestamp provenance_data source_code full_path filename)a

  def new do
    %__MODULE__{slots: %{}}
  end

  def put(%__MODULE__{} = ws, key, content, type \\ :text) do
    key = to_string(key)
    content = compact_artifact(content)

    if duplicate_content?(ws.slots, key, content) do
      ws
    else
      slot_key = next_slot_key(ws.slots, key)
      slot = Slot.new(content, type)
      new_slots = Map.put(ws.slots, slot_key, slot)
      %{ws | slots: new_slots}
    end
  end

  def load(base_path) when is_binary(base_path) do
    case File.read(worksheet_path(base_path)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, slots} when is_map(slots) ->
            decoded = Map.new(slots, fn {key, value} -> {key, decode_slot(value)} end)

            if contains_source_code?(slots) do
              persist_compacted_slots(worksheet_path(base_path), decoded)
            end

            %__MODULE__{slots: decoded}

          _ ->
            new()
        end

      {:error, :enoent} ->
        new()

      {:error, reason} ->
        require Logger
        Logger.warning("Worksheet: Could not load persisted worksheet: #{inspect(reason)}")
        new()
    end
  end

  def load(_), do: new()

  defp decode_slot(%{"content" => content} = value) do
    %Slot{
      content: decode_content(content),
      type: decode_type(value["type"]),
      hash: value["hash"] || :crypto.hash(:sha256, Jason.encode!(content)) |> Base.encode16(),
      timestamp: value["timestamp"] || System.system_time(:second)
    }
  end

  defp decode_slot(value), do: Slot.new(value, :artifact)

  defp decode_content(%{"artifact_hash" => _hash, "fact_text" => _fact} = content) do
    attrs =
      Enum.reduce(@dbc_fields, %{}, fn field, acc ->
        key = Atom.to_string(field)
        if Map.has_key?(content, key), do: Map.put(acc, field, Map.get(content, key)), else: acc
      end)

    attrs =
      case attrs[:timestamp] do
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, datetime, _offset} -> Map.put(attrs, :timestamp, datetime)
            _ -> attrs
          end

        _ ->
          attrs
      end

    attrs
    |> then(&struct(ACN.Core.Artifacts.DBC, &1))
    |> compact_artifact()
  end

  defp decode_content(content), do: compact_artifact(content)

  # Keep the source in the workspace file and in the transient DBC used for
  # ingestion, but never in worksheet memory or persistence.
  defp compact_artifact(%ACN.Core.Artifacts.DBC{} = artifact),
    do: %{artifact | source_code: nil}

  defp compact_artifact(%{} = artifact) do
    has_artifact_identity? =
      (Map.has_key?(artifact, :artifact_hash) or Map.has_key?(artifact, "artifact_hash")) and
        (Map.has_key?(artifact, :fact_text) or Map.has_key?(artifact, "fact_text"))

    if has_artifact_identity? do
      artifact
      |> Map.delete(:source_code)
      |> Map.delete("source_code")
      |> Map.new(fn {key, value} -> {key, compact_nested_artifacts(value)} end)
    else
      Map.new(artifact, fn {key, value} -> {key, compact_nested_artifacts(value)} end)
    end
  end

  defp compact_artifact(value), do: value

  defp compact_nested_artifacts(%ACN.Core.Artifacts.DBC{} = artifact),
    do: compact_artifact(artifact)

  defp compact_nested_artifacts(%{} = value), do: compact_artifact(value)

  defp compact_nested_artifacts(values) when is_list(values),
    do: Enum.map(values, &compact_nested_artifacts/1)

  defp compact_nested_artifacts(value), do: value

  defp contains_source_code?(value) when is_map(value) do
    source = Map.get(value, "source_code") || Map.get(value, :source_code)

    (is_binary(source) and source != "") or
      Enum.any?(value, fn {_key, nested} -> contains_source_code?(nested) end)
  end

  defp contains_source_code?(values) when is_list(values),
    do: Enum.any?(values, &contains_source_code?/1)

  defp contains_source_code?(_), do: false

  defp persist_compacted_slots(path, slots) do
    case Jason.encode(slots, pretty: true) do
      {:ok, json} ->
        case File.write(path, json) do
          :ok ->
            :ok

          {:error, reason} ->
            require Logger
            Logger.warning("Worksheet: Could not remove legacy source bodies: #{inspect(reason)}")
        end

      {:error, reason} ->
        require Logger
        Logger.warning("Worksheet: Could not encode compacted legacy data: #{inspect(reason)}")
    end
  end

  defp decode_type(type) when type in ["code", "plan", "text", "rule", "artifact"],
    do: String.to_existing_atom(type)

  defp decode_type(_), do: :artifact

  defp duplicate_content?(slots, key, content) do
    Enum.any?(slots, fn {slot_key, slot} ->
      (slot_key == key or String.starts_with?(slot_key, key <> "#")) and
        same_content?(slot.content, content)
    end)
  end

  defp same_content?(%{artifact_hash: hash}, %{artifact_hash: hash}) when is_binary(hash),
    do: true

  defp same_content?(%{"artifact_hash" => hash}, %{artifact_hash: hash}) when is_binary(hash),
    do: true

  defp same_content?(%{artifact_hash: hash}, %{"artifact_hash" => hash}) when is_binary(hash),
    do: true

  defp same_content?(left, right), do: left == right

  defp next_slot_key(slots, key) do
    if Map.has_key?(slots, key) do
      index =
        Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(not Map.has_key?(slots, "#{key}##{&1}")))

      "#{key}##{index}"
    else
      key
    end
  end

  defp worksheet_path(base_path) do
    real_base_path =
      if Path.extname(base_path) != "", do: Path.dirname(base_path), else: base_path

    Path.join([real_base_path, ".acn", "worksheet.json"])
  end

  defp merge_persisted(existing, incoming) do
    Enum.reduce(incoming.slots, existing, fn {key, slot}, acc ->
      put(acc, key, slot.content, slot.type)
    end)
  end

  def get(%__MODULE__{} = ws, key) do
    Map.get(ws.slots, key)
  end

  def to_map(%__MODULE__{} = ws) do
    # Returns a simple map of {key => content} for easier consumption
    Enum.reduce(ws.slots, %{}, fn {k, slot}, acc ->
      Map.put(acc, k, slot.content)
    end)
  end

  def save(%__MODULE__{} = ws, base_path) do
    if base_path do
      file_path = worksheet_path(base_path)

      # Ensure directory exists (redundant safety)
      File.mkdir_p!(Path.dirname(file_path))

      persisted = load(base_path)
      worksheet = merge_persisted(persisted, ws)

      case Jason.encode(worksheet.slots, pretty: true) do
        {:ok, json} ->
          File.write(file_path, json)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_path}
    end
  end
end
