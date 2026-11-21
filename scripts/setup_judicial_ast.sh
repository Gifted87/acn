#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cargo build --release --manifest-path "$repo_root/native/judicial_ast/Cargo.toml"
mkdir -p "$repo_root/priv/judicial_ast"
cp "$repo_root/native/judicial_ast/target/release/tree_sitter_ast" "$repo_root/priv/judicial_ast/tree_sitter_ast"
chmod +x "$repo_root/priv/judicial_ast/tree_sitter_ast"
