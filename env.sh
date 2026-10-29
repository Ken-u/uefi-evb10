#!/bin/bash
# Sourced by the scripts of this repository. Machine-specific paths, hosts and accounts live in ./.env
# (git-ignored, template .env.example); nothing in the committed files is personal.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export UEFI_EVB10_ROOT="$_here"
if [ -f "$_here/.env" ]; then set -a; . "$_here/.env"; set +a; fi
if [ -n "${CLANG_BIN:-}" ]; then export CLANGDWARF_BIN="${CLANGDWARF_BIN:-$CLANG_BIN}"; fi
