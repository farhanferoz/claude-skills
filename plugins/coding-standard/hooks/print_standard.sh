#!/usr/bin/env bash
# SessionStart: put the coding standard into the session's context. A plugin's own CLAUDE.md is not loaded
# (code.claude.com/docs/en/plugins-reference.md), but SessionStart stdout is (code.claude.com/docs/en/hooks.md).
set -euo pipefail
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cat "$here/../reference/coding-standards.md"
