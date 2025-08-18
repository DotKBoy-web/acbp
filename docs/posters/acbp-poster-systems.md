---
title: ACBP — A SQL-Native Equation for Deterministic Decision Spaces (Poster Abstract)
authors: Muteb Hail S. Al Anazi (DotK)
venue: Systems/DB Poster (CIDR/SIGMOD demo-style)
date: 2025-08-18 (Asia/Riyadh)
---

**Premise.** Decision logic is frequently scattered across BI tools and app code. We propose **ACBP**, a compact equation with a compiler to SQL that **materializes the decision space** and validates it with **machine-checkable theorems**.

**Model.** Flags `F ∈ {0,1}^B`, categories `c ∈ C`, rules `R`. Validity `ACBP(F,c) := ∧_{r∈R} r(F,c)`. Decision space `D = { (F,c) | ACBP(F,c) }`. Valid masks `M = { F | ∃ c: ACBP(F,c) }`. We enforce **strict** `M = π_F(D)` by defining `*_valid_masks_mat := SELECT DISTINCT mask FROM *_decision_space_mat`.

**Properties (proved + verified):**
1) **Soundness/Completeness:** `D_sql = D`.
2) **Projection:** `M_sql = π_F(D_sql)`.
3) **Present-only monotonicity:** if `C'` grows then `D_present` grows.
4) **Deterministic δ:** unique action per `(F,c)` when defined; enforced by keys.

**System.** PostgreSQL artifacts (validators, materialized views, unique indexes), a **verifier** (`sql/verify_theorems_public_auto.sql`), and a **Streamlit** app that plots P50/P95 and daily SLO (Wilson bound). All numbers below are **from the DB**, not mocked.

**Latency results (end-to-end joins; n=1,680 per model):**
- Clinic: **P50 ≈ 818 ms**, **P95 ≈ 937 ms**
- Inpatient: **P50 ≈ 614 ms**, **P95 ≈ 750 ms**
- Daily SLO: Clinic ≥95% under 920 ms; Inpatient ~83–91% under 700 ms (Wilson 95% lower bounds).

**Takeaway.** ACBP collapses ad-hoc rule code into a **single SQL-native equation** with **verifiable guarantees** while meeting **interactive** latencies. It aims to be the “**deterministic core**” under dashboards and decision services.
