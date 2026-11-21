use std::{env, fs, process};
use tree_sitter::{Language, Node, Parser};

fn language_for(path: &str) -> Option<(&'static str, Language)> {
    match path.rsplit('.').next()?.to_ascii_lowercase().as_str() {
        "ts" | "mts" | "cts" => Some(("typescript", tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into())),
        "tsx" => Some(("tsx", tree_sitter_typescript::LANGUAGE_TSX.into())),
        "js" | "mjs" | "cjs" | "jsx" => Some(("javascript", tree_sitter_javascript::LANGUAGE.into())),
        _ => None,
    }
}

fn count_nodes(node: Node<'_>) -> usize {
    let mut total = 1;
    for index in 0..node.child_count() {
        if let Some(child) = node.child(index) {
            total += count_nodes(child);
        }
    }
    total
}

fn main() {
    let path = env::args().nth(1).unwrap_or_else(|| {
        eprintln!("Usage: tree_sitter_ast <source-file>");
        process::exit(2);
    });
    let (language_name, language) = language_for(&path).unwrap_or_else(|| {
        eprintln!("Unsupported file extension for Tree-sitter AST: {path}");
        process::exit(2);
    });
    let source = fs::read_to_string(&path).unwrap_or_else(|error| {
        eprintln!("Could not read {path}: {error}");
        process::exit(2);
    });
    let mut parser = Parser::new();
    parser.set_language(&language).unwrap_or_else(|error| {
        eprintln!("Could not initialize {language_name} grammar: {error}");
        process::exit(2);
    });
    let tree = parser.parse(&source, None).unwrap_or_else(|| {
        eprintln!("Tree-sitter did not produce a syntax tree.");
        process::exit(2);
    });
    let root = tree.root_node();
    println!("language: {language_name}");
    println!("root: {}", root.kind());
    println!("nodes: {}", count_nodes(root));
    println!("has_syntax_errors: {}", root.has_error());
    println!("top_level:");
    for index in 0..root.named_child_count() {
        if let Some(child) = root.named_child(index) {
            let start = child.start_position();
            println!("  {} @ {}:{}", child.kind(), start.row + 1, start.column + 1);
        }
    }
    if root.has_error() {
        println!("syntax_errors:");
        report_errors(root);
    }
}

fn report_errors(node: Node<'_>) {
    if node.is_error() || node.is_missing() {
        let start = node.start_position();
        println!("  {} @ {}:{}", if node.is_missing() { "missing syntax" } else { "syntax error" }, start.row + 1, start.column + 1);
    }
    for index in 0..node.child_count() {
        if let Some(child) = node.child(index) {
            if child.has_error() || child.is_error() || child.is_missing() {
                report_errors(child);
            }
        }
    }
}
