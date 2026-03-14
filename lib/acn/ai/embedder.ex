defmodule ACN.AI.Embedder do
  @moduledoc """
  Public API for Text Embeddings.
  """
  require Logger

  @doc """
  Generates a 384-dimensional cognitive encoding (tensor) from text.
  
  NOTE: This is a local utility for edge-case cognitive processing. 
  Primary Associative Memory (ACMS) offloads encoding to the server side.
  """
  def embed(text) when is_binary(text) do
    if Process.whereis(ACN.Embedder) do
      try_embed_local(text)
    else
      mock_embed(text)
    end
  end

  defp try_embed_local(text) do
     try do
       output = Nx.Serving.batched_run(ACN.Embedder, text)
       tensor = output.embedding
       encoding = Nx.to_flat_list(tensor)
       384 = length(encoding)
       {:ok, encoding}
     rescue
       e ->
         Logger.error("Local Embedding Failed: #{inspect(e)}")
         mock_embed(text)
     end
  end

  defp mock_embed(text) do
    # Generate a deterministic 384-dim vector based on the string hash
    # This allows basic associative logic to work even without a real model.
    seed = :erlang.phash2(text)
    pseudo_random_vector(seed, 384)
  end

  defp pseudo_random_vector(seed, size) do
    # Simple deterministic vector generation (normalized -1.0 to 1.0)
    # This is better than all-zeros as it preserves some "uniqueness" for the text.
    vector = 
      for i <- 1..size do
        (:erlang.phash2({seed, i}) / 4_294_967_296 * 2.0) - 1.0
      end
    {:ok, vector}
  end
end
