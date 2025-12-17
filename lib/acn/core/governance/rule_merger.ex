defmodule ACN.Core.Governance.RuleMerger do
  @moduledoc """
  Mechanistically merges rules from Master, Ancestors, and Local context.
  Enforces Hierarchy: Master > Parent > Child.
  """

  @doc """
  Merges rule lists into a definitive Policy.
  """
  def merge(master, ancestral, local) do
    # 1. Flatten
    all_rules = master ++ ancestral ++ local
    
    # 2. Sort by Priority (Descending) then Timestamp (Descending)
    # To prefer Master (higher priority) over others, sorting DESC by Priority is key.
    # For rules with the same priority, newer rules (higher timestamp) should take precedence.
    sorted_rules = 
      Enum.sort_by(all_rules, fn r -> 
         ts = Map.get(r, :timestamp, 0)
         prio = Map.get(r, :priority, 0)
         {prio, ts}
      end, :desc)
      
    # 3. Deduplicate by ID
    # Enum.uniq_by keeps the *first* element it sees.
    # Since we sorted by Priority DESC, the highest priority version of an ID stays.
    deduplicated = Enum.uniq_by(sorted_rules, fn r -> r.id end)
    
    # 4. Semantic Filter (Future Hook)
    filter_conflicts(deduplicated)
  end

  defp filter_conflicts(rules) do
    # Use AI Mediator to resolve semantic conflicts
    # We pass the full rule structs
    vars = %{rules: rules}
    
    case ACN.Core.ProfileLoader.load("governance_mediator", vars) do
      {:ok, profile} ->
         buffer = ACN.AI.ContextBuffer.new(profile["system_prompt"])
         adapter = Application.get_env(:acn, :ai)[:default_adapter] || ACN.AI.Adapters.OpenAI
         config = %{adapter: adapter, opts: [model: profile["model"], temperature: profile["temperature"]]}
         
         case ACN.AI.Pipeline.run(buffer, [], config) do
           {:ok, msg, _} ->
             try do
                valid_descriptions = Jason.decode!(msg.content)
                # We need to map back to Rule structs.
                # This is tricky if description changed.
                # Strategy: Filter 'rules' where rule.description is in 'valid_descriptions' (fuzzy or exact)
                # Or just trust the AI output if we only need strings downstream? 
                # The system uses Structs.
                # The AI returns descriptions. We filter based on that.
                
                Enum.filter(rules, fn r -> 
                  # Check if r.description is "semantically present" in valid_descriptions
                  # For exact match:
                  r.description in valid_descriptions
                end)
             rescue
                _ -> rules # Fallback to mechanical merge rules
             end
           {:error, _} -> rules
         end
      {:error, _} -> rules
    end
  end
end
