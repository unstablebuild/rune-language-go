#!/usr/bin/env bash
# Verifies the built release tarball. Run via `make test`.
#
# It checks what ships, not the steps that built it, so dropping a build step
# cannot also drop its check.
#
# Guards:
#   1. macOS targets: Rune.app can load the package. Every Mach-O file is
#      signed by the $TEAM_ID Developer ID, and tree-sitter.so loads into a
#      process signed like Rune.app (scripts/macos-signing.sh check). Rune runs
#      with library validation, so an ad-hoc signed tree-sitter.so fails to
#      load with "different Team IDs", as in v1.27.1-ub.2 and ub.3.
set -euo pipefail

TAR="${TAR:-go.tar.gz}"
: "${TARGET_OS:?TARGET_OS is not set; run 'make test'}"
: "${TARGET_ARCH:?TARGET_ARCH is not set; run 'make test'}"

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

if [ "$TARGET_OS" != darwin ]; then
	echo "ok: no checks for $TARGET_OS packages"
	exit 0
fi
: "${TEAM_ID:?TEAM_ID is not set; run 'make test'}"
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is not set; run 'make test'}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
tar -xzf "$TAR" -C "$workdir"

"$(dirname "$0")/macos-signing.sh" check "$workdir" tree_sitter_go