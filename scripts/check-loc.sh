#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNT="$(find "$ROOT/src" -type f -print0 | xargs -0 awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }')"
echo "src LOC: $COUNT"
if [ "$COUNT" -lt 3000 ] || [ "$COUNT" -gt 4000 ]; then
  echo "src LOC out of requested range 3000-4000" >&2
  exit 1
fi

