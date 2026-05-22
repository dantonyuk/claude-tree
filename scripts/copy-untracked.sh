#!/usr/bin/env bash
# Copy all gitignored files at the repo root (non-recursive, regular files only).
# Usage: copy-untracked.sh <SRC> <DST>

set -uo pipefail

SRC="${1:-}"
DST="${2:-}"

if [[ -z "$SRC" || -z "$DST" ]]; then
  echo "usage: copy-untracked.sh <SRC> <DST>" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: SRC is not a directory: $SRC" >&2
  exit 1
fi

if [[ ! -d "$DST" ]]; then
  echo "ERROR: DST is not a directory: $DST" >&2
  exit 1
fi

cd "$SRC" || exit 1

count=0
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  case "$entry" in
    */)  continue ;;
    */*) continue ;;
  esac
  if [[ -f "$SRC/$entry" ]]; then
    if cp -p "$SRC/$entry" "$DST/$entry" 2>/dev/null; then
      echo "  copied: $entry"
      count=$((count + 1))
    else
      echo "  skipped (copy failed): $entry" >&2
    fi
  fi
done < <(git ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

if (( count == 0 )); then
  echo "  (no gitignored root files to copy)"
fi
