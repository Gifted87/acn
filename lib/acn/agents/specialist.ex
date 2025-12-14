defmodule ACN.Agents.Specialist do
  use GenServer
  require Logger
  alias ACN.Core.NodeRegistry
  alias ACN.Core.Router
  alias ACN.Tools.SpecialistTools

  defmodule SpecialistState do
    defstruct worksheet: %{}, task_context: nil, conversation_history: [], turns: 0
  end

  # --- Public API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: via_tuple())
  end

  defp via_tuple do
    NodeRegistry.via_tuple(:specialist, :specialist)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    initial_state =
      case ACN.Infrastructure.StateBackup.restore("specialist") do
        {:ok, restored_state} ->
           Logger.info("Restored Specialist State from backup.")
           restored_state
        _ ->
           %SpecialistState{}
      end
    {:ok, initial_state}
  end

  @impl true
  def handle_cast({:execute_draft, instruction, rules, immutable_context}, _state) do
    Logger.info("Specialist received task. Entering Cognitive Loop...")
    start_cognitive_loop(instruction, rules, immutable_context, %{})
  end

  @impl true
  def handle_cast({:execute_refactor, defect_report, rules, existing_worksheet}, _state) do
    Logger.info("Specialist received REFACTOR task.")
    instruction = "Refactor the existing code to fix the following defects:\n#{defect_report}"
    # Refactor uses existing worksheet as base, and empty immutable context (or we should persist it?)
    # For now, empty or basic.
    start_cognitive_loop(instruction, rules, %ACN.Core.Artifacts.ImmutableContext{}, existing_worksheet)
  end

  defp start_cognitive_loop(instruction, rules, immutable_context, initial_worksheet) do
    new_context = %{
      instruction: instruction,
      rules: rules,
      env: immutable_context # Storing it here
    }

    # Initialize Prompt
    system_prompt = """
    You are the Specialist, an expert Elixir Engineer.
    Your goal is to implement or repair the requested code in your Virtual Worksheet (RAM).

    Instruction: #{instruction}
    Rules: #{inspect(rules)}
    
    Existing Codebase: #{inspect(immutable_context.codebase_map)}

    You have tools to write and read files in your worksheet.
    You must iterate until the code is correct.
    Use 'worksheet_write' to create files.
    When finished, call 'submit_draft'.
    """

    # Create Initial State
    initial_buffer = ACN.AI.ContextBuffer.new(system_prompt)

    # Trigger Async Loop
    GenServer.cast(self(), {:cognitive_step, initial_buffer})

    {:noreply, %SpecialistState{
      worksheet: initial_worksheet,
      task_context: new_context,
      conversation_history: [],
      turns: 0
    }}
  end

  @impl true
  def handle_cast({:cognitive_step, buffer}, state) do
     if state.turns >= 10 do
        Logger.error("Cognitive Exhaustion Reached (10 turns). Aborting.")
        Router.route({:action_failure, "Cognitive Exhaustion"}, {:local, :controller})
        {:noreply, state}
     else
        config = %{
           adapter: ACN.AI.Adapters.OpenAI,
           opts: [model: "gpt-4o", temperature: 0.2] # Use smart model for coding
        }
        tools = SpecialistTools.definitions()

        Logger.info("Thinking... (Turn #{state.turns + 1})")

        case ACN.AI.Pipeline.run(buffer, tools, config) do
          {:ok, response, new_buffer} ->
             process_response(response, new_buffer, state)

          error ->
             Logger.error("AI Error: #{inspect(error)}")
             # Retry? Or fail.
             {:noreply, state}
        end
     end
  end

  defp process_response(response, buffer, state) do
      # 1. Check for Tool Calls
      case response.tool_calls do
        nil ->
            # No tool call? Just thought.
            Logger.info("Specialist Thoughts: #{response.content}")
            # Recurse (maybe LLM is just talking)
            continue_loop(buffer, state)

        calls ->
            # Execute Tools
            {updated_buffer, updated_worksheet, terminate?} =
              execute_tools(calls, buffer, state.worksheet, state.task_context.env)

            if terminate? do
               Logger.info("Specialist submitted draft.")
               # Submit Payload
               payload = %{artifact_type: :code, content: updated_worksheet}
               Router.route({:draft_result, payload}, {:local, :controller})
               {:noreply, %{state | worksheet: updated_worksheet, turns: state.turns + 1}}
            else
               # Continue Loop
               continue_loop(updated_buffer, %{state | worksheet: updated_worksheet})
            end
      end
  end

  defp execute_tools(calls, buffer, worksheet, context) do
      Enum.reduce(calls, {buffer, worksheet, false}, fn call, {buf, ws, term} ->
          # Parse Arguments (usually JSON string)
          args =
             if is_binary(call["function"]["arguments"]) do
                 Jason.decode!(call["function"]["arguments"])
             else
                 call["function"]["arguments"]
             end

          tool_call_struct = %{"name" => call["function"]["name"], "arguments" => args}

          # Execute
          # We pass context as 3rd argument
          case SpecialistTools.execute(tool_call_struct, ws, context) do
             {:ok, output, new_ws} ->
                 # Self-Correction Hook for Writes
                 final_output = check_syntax(tool_call_struct["name"], args, new_ws, output)

                 # Append Tool Output to Buffer
                 new_buf = ACN.AI.ContextBuffer.add_tool_result(buf, call["id"], final_output)
                 {new_buf, new_ws, term}

             {:ok, _output, new_ws, :terminate} ->
                 # Submission
                 {buf, new_ws, true}

             _ -> {buf, ws, term}
          end
      end)
  end

  defp continue_loop(buffer, state) do
     # Backup State
     ACN.Infrastructure.StateBackup.backup("specialist", state)

     GenServer.cast(self(), {:cognitive_step, buffer})
     {:noreply, %{state | turns: state.turns + 1}}
  end

  defp check_syntax("worksheet_write", args, _ws, original_output) do
     filename = args["filename"]
     content = args["content"]

     if String.ends_with?(filename, ".ex") or String.ends_with?(filename, ".exs") do
         case Code.string_to_quoted(content) do
             {:ok, _} ->
                 original_output
             {:error, {line, error, _token}} ->
                 "Error: Your code for #{filename} has a Syntax Error on line #{line}: #{inspect(error)}. Please fix it immediately."
         end
     else
         original_output
     end
  end

  defp check_syntax(_, _, _, output), do: output

end
