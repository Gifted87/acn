defmodule ACN.AI.Embedder do
  @moduledoc """
  Public API for Text Embeddings.
  """
  require Logger

  @doc """
  Generates a 384-dimensional vector from text.
  """
  def embed(text) when is_binary(text) do
     try do
       output = Nx.Serving.batched_run(ACN.Embedder, text)

       # Bumblebee returns a struct with `embedding` tensor.
       tensor = output.embedding

       # Convert to flat list
       vector = Nx.to_flat_list(tensor)

       384 = length(vector) # Assert dimension

       {:ok, vector}
     rescue
       e ->
         Logger.error("Embedding Failed: #{inspect(e)}")
         {:error, e}
     end
  end
end
