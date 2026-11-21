defmodule ACN.Tools.Judicial.ParseAst do
  @behaviour ACN.Tools.ToolBehaviour

  alias ACN.Tools.Judicial.WorkspaceFile

  @impl true
  def definition do
    %{
      "name" => "judicial_parse_ast",
      "description" => "Parses TypeScript, TSX, and JavaScript source with Tree-sitter and returns a structural AST summary and syntax-error locations.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "description" => "Workspace file to parse."}},
        "required" => ["path"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    with {:ok, path} <- WorkspaceFile.resolve(args, env),
         {:ok, _source} <- File.read(path),
         {:ok, parser} <- parser_runtime() do
      case System.cmd(parser, [path], stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, _status} -> {:error, String.trim(output)}
      end
    else
      {:error, reason} -> {:error, "AST parsing failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "AST parser failed: #{Exception.message(error)}"}
  end

  defp parser_runtime do
    root = Application.get_env(:acn, :judicial_ast_root, Path.expand("priv/judicial_ast"))
    parser = Path.join(root, "tree_sitter_ast")

    if File.regular?(parser),
      do: {:ok, parser},
      else: {:error, "Tree-sitter parser binary is missing; run scripts/setup_judicial_ast.sh."}
  end
end
