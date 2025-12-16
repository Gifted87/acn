defmodule ACN.AI.LLM.Serving do
  @moduledoc """
  The Hippocampus: Hosts the Tiny-Agent 1.5B model.
  Serves as the cognitive engine for ACN.
  """
  require Logger

  @repo_id "driaforall/Tiny-Agent-a-1.5B"
  @serving_name ACN.LocalLLM

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(_opts \\ []) do
    Logger.info("Starting ACN.AI.LLM.Serving (The Hippocampus)...")
    Logger.info("Loading model from #{@repo_id}. This may take a while...")

    # 1. Load Model & Tokenizer
    # Qwen2 is Llama-compatible, forcing Llama module if Qwen2 not found
    {:ok, model_info} = Bumblebee.load_model({:hf, @repo_id}, module: Bumblebee.Text.Llama, architecture: :for_causal_language_modeling)
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @repo_id}, module: Bumblebee.Text.LlamaTokenizer)
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, @repo_id})

    # 2. Configure Generation
    # Strategy: Multinomial, top_p 0.95, temp 0.1 (low temp for precision)
    # Max tokens: 4096
    generation_config =
      Bumblebee.configure(generation_config,
        max_new_tokens: 4096,
        strategy: %{
          type: :multinomial_sampling,
          top_p: 0.95
        },
        temperature: 0.1
      )

    # 3. Create Serving with EXLA Compilation
    # Batch Size 1, Sequence Length 4096 for high-context single-user
    serving =
      Bumblebee.Text.generation(model_info, tokenizer, generation_config,
        compile: [
          batch_size: 1,
          sequence_length: 4096
        ],
        defn_options: [compiler: EXLA]
      )

    Logger.info("Model loaded and serving compiled. Starting Nx.Serving process under name #{inspect(@serving_name)}...")

    # 4. Start Serving Process
    Nx.Serving.start_link(name: @serving_name, serving: serving)
  end
end
