#!/usr/bin/env bash
# Print the release notes for one version: the body of its "## <version>" section in docs/CHANGELOG.md.
# Fails if the section is missing or empty, so a release cannot go out without notes.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: scripts/release-notes.sh <version>}"
BODY=$(awk -v v="$V" '
  /^## / { if (found) exit; if ($2 == v) { found = 1; next } }
  found { print }
' docs/CHANGELOG.md)
# Trim blank lines at both ends, and refuse an empty section.
BODY=$(printf '%s\n' "$BODY" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')
[ -n "$BODY" ] || { echo "no release notes for $V in docs/CHANGELOG.md" >&2; exit 1; }
printf '%s\n' "$BODY"
