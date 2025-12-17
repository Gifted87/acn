defmodule ACN.AI do
  @moduledoc """
  Public API for the Artificial Intelligence subsystems of the ACN.
  Facades the Cognitive Pipeline and Embedding Engine.
  """

  alias ACN.AI.Pipeline
  alias ACN.AI.ContextBuffer
  alias ACN.AI.Embedder

  @doc """
  Runs a chat session with the AI.
  Wraps Pipeline.run/3.
  """
  def chat(messages, tools \\ [], opts \\ []) do
     # Convert raw list of maps to ContextBuffer if needed, or create new
     buffer =
       if is_list(messages) do
         ContextBuffer.new(messages)
       else
         messages
       end

     adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
     
     config = %{
       adapter: adapter,
       opts: opts
     }

     case Pipeline.run(buffer, tools, config) do
       {:ok, msg, _updated_buffer} ->
          {:ok, msg.content}
       error ->
          error
     end
  end

  @doc """
  Generates text embeddings.
  Delegates to ACN.AI.Embedder.
  """
  def embed(text), do: Embedder.embed(text)

end
