# Changelog
All notable changes to this project will be documented in this file.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and uses [Semantic Versioning](https://semver.org/).

---

## [0.4.0] — 2025-08-18

### Added
- **Paper & artifacts**
  - `papers/acbp-systems-paper.md` and compiled `papers/acbp-systems-paper.pdf`.
  - `papers/metadata.yaml`, `papers/references.bib`.
  - Benchmark exports under `papers/results/<timestamp>/**` (plans, summaries, KPI CSVs, dashboard timings).
  - `papers/README-papers.md` with build/run notes.
- **Datasets**
  - `dataset/clinic_visit_data_part{1,2}.csv` (50k rows total).
  - `dataset/inpatient_admission_data_part{1,2}.csv` (50k rows total).
- **SQL emitters**
  - Generated SQL for v0 models: `models/clinic_visit.v0.sql`, `models/inpatient_admission.v0.sql`.
- **Versioning**
  - Root `VERSION` file set to `0.4.0`.

### Changed
- **Repo layout**
  - Move DSL model JSONs from `docs/models/` → `models/`:
    - `models/clinic_visit.v0.json`
    - `models/inpatient_admission.v0.json`
- **Build & scripts**
  - Updates to `acbp.sh`, `acbp_tester.py`, and `make_data.py` to support paper benches, present-only materialization, and result export helpers.

### Fixed
- **Formatting & portability**
  - Normalize line endings (LF), trim trailing whitespace, and ensure EOF newlines (via pre-commit).
- **LaTeX/PDF build stability**
  - Use `pdflatex` path; add `fvextra` wrapping for code blocks.
  - Map Unicode symbols (− – — × ≤ ≥) to LaTeX equivalents to avoid compilation errors.

### Performance (headline results)
- **Clinic (9-query “dashboard” bundle, cold):** median **~820 ms** (p95 **~921 ms**); per-query medians mostly **~7–8 ms**, with top-groups **~340–426 ms** depending on full vs present-only.
- **Inpatient (cold):** bundle median **~607 ms** (p95 **~702 ms**).
- **Space pruning (structural):**
  - Clinic: naïve **607,500** → decision **295,650** (**48.7%**) → present-only **30,416** (**~5%** of naïve); bit-valid masks **7/32**.
  - Inpatient: naïve **241,920** → decision **126,000** (**52.1%**) → present-only **24,346** (**~10%** of naïve); bit-valid masks **20/64**.

### Removed
- Old root-level artifacts and duplicates:
  - `clinic_visit.json`, `inpatient_admission.json`.
  - Root CSV copies for clinic/inpatient.
  - Outdated schema drafts under `docs/schema/v1*`.

### Docs
- Update `CITATION.cff` for v0.4.0 (title, authors, URLs, release date).

### Migration notes
- If you referenced models under `docs/models/`, update paths to `models/`.
- Paper build is now reproducible from `papers/` (see `papers/README-papers.md`).

---

## Earlier history
See Git history and release notes prior to 0.4.0.

[0.4.0]: https://github.com/DotKBoy-web/acbp/releases/tag/v0.4.0
