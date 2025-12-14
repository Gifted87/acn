defmodule ACN.AI.Embedder.Serving do
  @moduledoc """
  Top-level supervision for the Bumblebee Serving process.
  Loads the 'all-MiniLM-L6-v2' model and exposes it as an Nx.Serving.
  """
  require Logger

  @model_repo "sentence-transformers/all-MiniLM-L6-v2"

  def start_link(_opts) do
     Logger.info("Booting Visual Cortex (Bumblebee)...")

     # Load Model & Tokenizer
     {:ok, model_info} = Bumblebee.load_model({:hf, @model_repo})
     {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_repo})

     # Create Serving
     serving = Bumblebee.Text.text_embedding(model_info, tokenizer,
       output_pool: :mean_pooling,
       output_attribute: :hidden_state,
       compile: [batch_size: 8, sequence_length: 64],
       defn_options: [compiler: EXLA]
     )

     # Start Serving Process (Global Name)
     Nx.Serving.start_link(name: ACN.Embedder, serving: serving, batch_size: 8, batch_timeout: 100)
  end

  # Nx.Serving.start_link handles the process.
  # We wrap in a Supervisor if we want more control, but for now we'll put this module in the tree directly
  # Or rather, we use this module to Init and Return the child spec.

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
