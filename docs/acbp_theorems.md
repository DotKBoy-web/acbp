---
layout: default
title: ACBP — Theorems & Proofs (Verified)
---

# ACBP Decision Space — Theorems & Proofs
_Prepared: 2025-08-18 (Asia/Riyadh)_
…

# ACBP Decision Space — Theorems & Proofs
_Prepared: 2025-08-18 (Asia/Riyadh)_

This document states the formal properties of the Al Anazi Categorical-Boolean Paradigm (ACBP) and provides point-by-point proofs aligned with the compiler contract and SQL artifacts.

---

## 0) Implementation binding (strict \(M=\pi_F(D)\)) — **current**
**Schemas/objects (public):**
- `clinic_visit_decision_space_mat`, `inpatient_admission_decision_space_mat`
- `clinic_visit_valid_masks_mat`, `inpatient_admission_valid_masks_mat` — **defined as** `SELECT DISTINCT mask FROM <model>_decision_space_mat`
- Bit-only diagnostics retained as: `clinic_visit_valid_masks_bit_mat`, `inpatient_admission_valid_masks_bit_mat`

**Result:** \(M\) is implemented as the **projection** of \(D\). Coverage holds by construction.

---

## 1) Setup: Notation & Assumptions

- **Bits (flags).** \(F \in \{0,1\}^B\).
- **Categories.** \(c \in C = \prod_i C_i\) where each \(C_i\) is finite.
- **Rules.** Finite set \(R\) of deterministic predicates \(r(F,c) \in \{\text{true},\text{false}\}\).
- **Predicate.** \(\mathrm{ACBP}(F,c) := \bigwedge_{r\in R} r(F,c)\).

**Core sets**
- **Valid masks (category-aware).** \(M := \{ F \mid \exists c \in C : \mathrm{ACBP}(F,c) \}\).
- **Decision space.** \(D := \{ (F,c) \in \{0,1\}^B \times C \mid \mathrm{ACBP}(F,c) \}\).
- **Observed categories.** \(C' \subseteq C\) (tuples actually observed in data).
- **Present-only decision space.** \(D_{\text{present}} := D \cap (\{0,1\}^B \times C')\).

**Decision mapping**
- \(\delta : D \to \mathrm{Actions}\) returns a deterministic action (e.g., route, priority).

**Compiler contract (SQL artifacts)**
- A validator equivalent to \(\mathrm{ACBP}\).
- A relation \(M_{\text{sql}}\) enumerating \(M\) (**implemented as** `SELECT DISTINCT mask FROM decision_space_mat`).
- A relation \(D_{\text{sql}}\) enumerating \(D\).
- A materialized view \(D_{\text{present,sql}}\) enumerating \(D_{\text{present}}\).
- \(\delta\) implemented as a total, deterministic mapping on \(D\) (e.g., CASE/lookup), with PK/UNIQUE keys enforced on \(D_{\text{sql}}\) (via unique indexes on matviews).

**Scope assumptions**
- Each \(C_i\) is finite (or effectively finite over the evaluation window).
- Each \(r\) compiles to a deterministic, total SQL predicate.
- \(\delta\) is deterministic and total on \(D\).

---

## 2) Theorem — Soundness of the Compiled Decision Space

**Claim.** If \((F,c) \in D_{\text{sql}}\), then \(\mathrm{ACBP}(F,c)\) holds.

**Proof (points).**
1. The compiler inserts \((F,c)\) into \(D_{\text{sql}}\) iff the SQL validator for \(\mathrm{ACBP}\) evaluates `true`.
2. Each \(r \in R\) is compiled to a semantically equivalent SQL predicate.
3. Therefore, membership in \(D_{\text{sql}}\) implies all \(r(F,c)\) hold.
4. Thus \(\bigwedge_{r\in R} r(F,c)\) holds, i.e., \(\mathrm{ACBP}(F,c)\) is true. ∎

---

## 3) Theorem — Completeness of the Compiled Decision Space

**Claim.** If \(\mathrm{ACBP}(F,c)\) holds, then \((F,c) \in D_{\text{sql}}\).

**Proof (points).**
1. The enumerator ranges over the finite superset \(\{0,1\}^B \times C\).
2. For each \((F,c)\) it evaluates the SQL validator of \(\mathrm{ACBP}\).
3. If \(\mathrm{ACBP}(F,c)\) is true, the row is inserted into \(D_{\text{sql}}\).
4. Finite enumeration + deterministic evaluation prevents skipping satisfying pairs.
5. Hence every satisfying \((F,c)\) appears in \(D_{\text{sql}}\). ∎

**Corollary 3.1 (Equivalence).** \(D_{\text{sql}} = D\).
_Reason:_ Soundness (Sec. 2) + Completeness (Sec. 3).

---

## 4) Proposition — Present-Only Monotonicity

**Claim.** If \(C'_1 \subseteq C'_2\) then \(D_{\text{present}}(C'_1) \subseteq D_{\text{present}}(C'_2)\).

**Proof (points).**
1. \(D_{\text{present}}(C') = D \cap (\{0,1\}^B \times C')\) by definition.
2. If \(C'_1 \subseteq C'_2\), then \(\{0,1\}^B \times C'_1 \subseteq \{0,1\}^B \times C'_2\).
3. Intersecting the same set \(D\) with a larger set can only grow (or keep) the result.
4. Therefore \(D_{\text{present}}(C'_1) \subseteq D_{\text{present}}(C'_2)\). ∎

---

## 5) Proposition — Valid Masks as a Projection of \(D\)

**Claim.** \(M = \{F \mid \exists c : (F,c) \in D\}\) and \(M_{\text{sql}}\) enumerates \(M\).

**Proof (points).**
1. By definition, \(M = \{F \mid \exists c \in C : \mathrm{ACBP}(F,c)\}\).
2. From Corollary 3.1, \(D_{\text{sql}} = D\).
3. The projection \(\pi_F(D) = \{F \mid \exists c : (F,c) \in D\}\) equals \(M\).
4. \(M_{\text{sql}}\) is implemented as `SELECT DISTINCT mask FROM decision_space_mat`, i.e., \(\pi_F(D_{\text{sql}})\).
5. Hence \(M_{\text{sql}}\) enumerates exactly \(M\). ∎

---

## 6) Theorem — Determinism & Uniqueness of the Decision Mapping

**Claim.** If \(\delta\) is total and functional on \(D\), then for any \((F,c) \in D\) there exists a unique action \(a\) with \(\delta(F,c)=a\).

**Proof (points).**
1. The SQL implementation of \(\delta\) (CASE/lookup) returns exactly one action per key \((F,c)\).
2. PK/UNIQUE constraints (unique index on key columns) prevent duplicate keys.
3. Deterministic evaluation yields the same result for the same inputs.
4. Therefore \(\delta\) returns a unique, stable action for each \((F,c) \in D\). ∎

---

## 7) Lemma — Finiteness & Termination

**Claim.** \(D\) and \(D_{\text{present}}\) are finite; enumeration terminates.

**Proof (points).**
1. \(|\{0,1\}^B| = 2^B\) and each \(|C_i| < \infty\) ⇒ \(|C| < \infty\).
2. Hence \(|\{0,1\}^B \times C| = 2^B \cdot |C| < \infty\).
3. \(D \subseteq \{0,1\}^B \times C\) and \(D_{\text{present}} \subseteq D\), so both are finite.
4. Exhaustive filtering over a finite set terminates. ∎

---

## 8) Verified properties (DB run)

**Environment:** container `acbp-pg` → DB `postgres` • _Verified: 2025-08-18 (Asia/Riyadh)_
**Models:** `clinic_visit`, `inpatient_admission`
**Verifier:** `sql/verify_theorems_public_auto.sql`

- **Soundness:** 0 violations
- **Coverage (strict \(M=\pi_F(D)\)):** 0 missing masks
- **Duplicate keys:** 0
- **δ determinism:** _skipped_ (no action columns yet)

---

## 9) Dataset deltas (bit-only vs category-aware)

We retain bit-only masks as diagnostics (`*_valid_masks_bit_mat`) and compare against strict \(M\).

- **Clinic Visit:** 7 → 6 masks (**−1, −14.29%**)
  **Dead masks:** `{8}`
- **Inpatient Admission:** 20 → 10 masks (**−10, −50.00%**)
  **Dead masks:** `{4,5,16,17,20,21,32,33,36,37}`

_Dead = bit-valid but invalid for **all** category tuples; these are tracked in `*_dead_masks_mat` and are excluded from runtime._

---

## 10) Temporal notes (if using time)

- Model time as:
  - (i) a categorical component of \(C\) (windowed, finite), or
  - (ii) constraints inside \(r(F,c)\) over a fixed evaluation window.
Either choice preserves finiteness and the theorems.

---

## 11) Implementation checklist (math → SQL)

- Enforce uniqueness on decision keys via **unique index** over `(mask + categorical dims)` on `*_decision_space_mat`.
- Keep validator predicates deterministic and side-effect free.
- `valid_masks_mat = SELECT DISTINCT mask FROM decision_space_mat` (strict).
- Maintain present-only as a materialized subset; monotonicity holds (Sec. 4).
- Keep parity tests: counts/joins vs validator outputs to confirm Sec. 2–3.
- When actions are added, enable the **multi-action ambiguity** check to enforce \(\delta\)’s uniqueness.

---

## 12) Repro commands (ops)

- Verify theorems:
  `bash scripts/verify-theorems.sh`
- Show dead masks:
  `TABLE public.clinic_visit_dead_masks_mat;` and
  `TABLE public.inpatient_admission_dead_masks_mat;`

---
