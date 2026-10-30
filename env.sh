#!/bin/bash
# Sourced by the scripts of this repository. Machine-specific paths, hosts and accounts live in ./.env
# (git-ignored, template .env.example); nothing in the committed files is personal.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export UEFI_EVB10_ROOT="$_here"
if [ -f "$_here/.env" ]; then set -a; . "$_here/.env"; set +a; fi
if [ -n "${CLANG_BIN:-}" ]; then export CLANGDWARF_BIN="${CLANGDWARF_BIN:-$CLANG_BIN}"; fi
# The board tools every RK3588 board needs (serial capture, U-Boot console, USB helpers, reset controller) live in
# UniXNU-rk3588-common/tools/board. RK3588_COMMON is that checkout; the default is the one next to this repository.
export RK3588_COMMON="${RK3588_COMMON:-$_here/../UniXNU-rk3588-common}"
export RK3588_BOARD_TOOLS="$RK3588_COMMON/tools/board"
