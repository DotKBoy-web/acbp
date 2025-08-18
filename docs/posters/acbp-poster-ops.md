---
title: ACBP — SQL-Native Decision Spaces for Clinical Ops (Poster Abstract)
authors: Muteb Hail S. Al Anazi (DotK)
venue: AMIA/ICHI Poster (abstract)
date: 2025-08-18 (Asia/Riyadh)
---

**Problem.** Clinical dashboards and decision flows often depend on opaque BI logic or probabilistic models with unclear guarantees. Operations teams need **deterministic**, auditable rules that compile to the database they already run.

**Approach.** We present the **Al Anazi Categorical-Boolean Paradigm (ACBP)**, a SQL-native equation for **deterministic decision spaces**. Let flags `F ∈ {0,1}^B` and categories `c ∈ C`. Validity is `ACBP(F,c) := ∧_{r∈R} r(F,c)`. The **decision space** `D = { (F,c) | ACBP(F,c) }` and **valid masks** `M = { F | ∃ c: ACBP(F,c) }`. In production, ACBP compiles to PostgreSQL: validator functions, `*_decision_space_mat`, and (strict) `*_valid_masks_mat = SELECT DISTINCT mask FROM *_decision_space_mat`. We ship a verifier that checks **soundness, completeness, coverage, dedup**, and present-only monotonicity.

**Theorems (verified on DB).**
Soundness (only valid rows enter `D_sql`), Completeness (`D_sql` equals `D`), Projection (`M = π_F(D)`), Deterministic mapping `δ` (unique action per `(F,c)` when enabled). Our CI script (`sql/verify_theorems_public_auto.sql`) reported **0 violations**.

**Results (live-style latency; n per model = 1,680):**
- *Clinic model:* **P50 ≈ 818 ms**, **P95 ≈ 937 ms**
- *Inpatient model:* **P50 ≈ 614 ms**, **P95 ≈ 750 ms**
- *Daily SLO (Wilson 95% lower bound):* Clinic ≥95% under 920 ms across days; Inpatient ~83–91% under 700 ms.

**Why it matters.** ACBP keeps policy in first-class SQL with **deterministic semantics**, **category-aware validation**, and **auditable refresh**. The numbers show **interactive** P50/P95 suitable for live dashboards—supporting the slogan **“logic @ the speed of thought”** without overclaiming.

**Artifacts.** Equation & proofs, verifier CI, datasets, and a Streamlit latency/KPI app are public: GitHub Pages + Zenodo DOIs.
