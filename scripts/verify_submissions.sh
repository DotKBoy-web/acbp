#!/usr/bin/env bash
set -euo pipefail

ROOT="docs/papers/submissions"
fail=0

check_file() {
  local f="$1"; shift
  if [[ ! -f "$f" ]]; then
    echo "✗ MISSING: $f"
    fail=$((fail+1))
    return
  fi
  echo "✓ FOUND:   $f"
  for pat in "$@"; do
    if grep -q -- "$pat" "$f"; then
      echo "  · ok: '$pat'"
    else
      echo "  · !! missing: '$pat'"
      fail=$((fail+1))
    fi
  done
}

check_file "$ROOT/README.md" \
  "ACBP — Abstracts & Submission Pack" \
  "10.5281/zenodo.16891510" \
  "10.5281/zenodo.16891549"

check_file "$ROOT/AMIA_Ops_Abstract.md" \
  "^# Title" "P50 818 ms" "P95 937 ms" "P50 614 ms" "P95 750 ms"

check_file "$ROOT/ICHI_Abstract.md" \
  "^# Title" "The ACBP Equation" "P50 ~818 ms" "P95 ~937 ms" "P50 ~614 ms" "P95 ~750 ms"

check_file "$ROOT/CIDR_Poster_Abstract.md" \
  "^# Title" "From Equation to MatView" "π_F"

check_file "$ROOT/Cover_Letters.md" \
  "Dear Program Committee" "Dear Chairs" "Dear CIDR Organizers"

check_file "$ROOT/Submission_Checklist.md" \
  "^# Submission Checklist" "## AMIA" "## IEEE ICHI" "## CIDR-style"

echo
if [[ $fail -eq 0 ]]; then
  echo "✅ All submission files pass presence & key-marker checks."
  exit 0
else
  echo "❌ $fail check(s) failed. See messages above."
  exit 1
fi
