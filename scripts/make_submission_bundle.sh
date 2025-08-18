#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
DATE_UTC="$(date -u +%Y%m%d)"
OUTDIR="$ROOT/dist/submissions-$DATE_UTC"
ZIP="$ROOT/dist/acbp-submissions-$DATE_UTC.zip"

# Inputs
SUB="$ROOT/docs/papers/submissions"
PAPER_HTML="$ROOT/docs/papers/acbp-systems-paper.html"
PAPER_PDF="$ROOT/docs/papers/acbp-systems-paper.pdf"
CIT="$ROOT/CITATION.cff"
LIC="$ROOT/LICENSE"

# Sanity
need() { [[ -f "$1" ]] || { echo "Missing: $1" >&2; exit 1; }; }
need "$SUB/README.md"
need "$SUB/AMIA_Ops_Abstract.md"
need "$SUB/ICHI_Abstract.md"
need "$SUB/CIDR_Poster_Abstract.md"
need "$SUB/Cover_Letters.md"
need "$SUB/Submission_Checklist.md"
need "$PAPER_PDF"
need "$LIC"
need "$CIT"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Copy core
cp -v "$SUB/README.md"                       "$OUTDIR/README.md"
cp -v "$SUB/AMIA_Ops_Abstract.md"            "$OUTDIR/AMIA_Ops_Abstract.md"
cp -v "$SUB/ICHI_Abstract.md"                "$OUTDIR/ICHI_Abstract.md"
cp -v "$SUB/CIDR_Poster_Abstract.md"         "$OUTDIR/CIDR_Poster_Abstract.md"
cp -v "$SUB/Cover_Letters.md"                "$OUTDIR/Cover_Letters.md"
cp -v "$SUB/Submission_Checklist.md"         "$OUTDIR/Submission_Checklist.md"
cp -v "$PAPER_PDF"                           "$OUTDIR/acbp-systems-paper.pdf"
cp -v "$PAPER_HTML"                          "$OUTDIR/acbp-systems-paper.html" || true
cp -v "$CIT"                                 "$OUTDIR/CITATION.cff"
cp -v "$LIC"                                 "$OUTDIR/LICENSE"

# Drop a short MANIFEST (money lines)
cat > "$OUTDIR/MANIFEST.md" <<'MD'
# ACBP Submissions — Manifest

- DOI (datasets): 10.5281/zenodo.16891510
- DOI (paper pack): 10.5281/zenodo.16891549

## “Money lines” (latency, verified)
- Clinic: P50 ≈ **818 ms**, P95 ≈ **937 ms** (n=1,680)
- Inpatient: P50 ≈ **614 ms**, P95 ≈ **750 ms** (n=1,680)
- Daily SLO (Wilson 95% LB): Clinic ≥ **95%** under 920 ms across days; Inpatient **~83–91%** under 700 ms.

## Pointers
- Equation & theorems: https://dotkboy-web.github.io/acbp/
- Repo: https://github.com/DotKBoy-web/acbp

MD

# Make zip (zip if available, else tar.gz)
mkdir -p "$ROOT/dist"
if command -v zip >/dev/null 2>&1; then
  (cd "$OUTDIR/.." && zip -r "$(basename "$ZIP")" "$(basename "$OUTDIR")")
else
  ZIP="${ZIP%.zip}.tar.gz"
  (cd "$OUTDIR/.." && tar -czf "$(basename "$ZIP")" "$(basename "$OUTDIR")")
fi

# Checksums for integrity
sha256sum "$ZIP" > "$ZIP.sha256" 2>/dev/null || shasum -a256 "$ZIP" > "$ZIP.sha256"

echo
echo "✅ Bundle ready:"
echo "  $ZIP"
echo "  $(cat "$ZIP.sha256")"
