# ACBP Release Procedure (Asia/Riyadh)

## 1) Prep version
- Update `CITATION.cff` `version` and `date-released`.
- Ensure README links to **docs/ACBP-Equation.md**.

## 2) Sign & tag locally
```bash
git add -A
git commit -m "Release v0.3.0: ACBP Equation, schema v1 patch, CI, citation"
git tag -s v0.3.0 -m "ACBP v0.3.0"
git push origin main --tags
```
## 3) Create GitHub Release

Title: ACBP v0.3.0

Notes: highlight the equation doc + schema patch. Attach any generated SQL artifacts if relevant.

## 4) Archive for provenance

Enable GitHub→Zenodo once; each tag mints/updates a DOI.

Trigger Software Heritage “Save Code Now” for the tag; include the SWHID in release notes.

## 5) Paper-friendly artifact

Attach compiled SQL for examples/clinic_visit_v1.json (optional) to make reviews easy.
