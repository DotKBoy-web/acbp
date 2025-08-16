# The ACBP Equation (canonical)

**Objects.**
- Flags: `F ∈ {0,1}^B` (ordered bitmask over boolean state).
- Categories: `c ∈ C = ∏_i C_i` (finite, typed dimensions).
- Rules: `R` (each rule is a predicate `r(F,c)`).

**Definition (validity).**
ACBP(F, c) := ∧_{r ∈ R} r(F, c)

**Sets.**
- **Valid masks:** `M = { F | ∃ c ∈ C : ACBP(F, c) }`
- **Decision space:** `D = { (F, c) ∈ {0,1}^B × C | ACBP(F, c) }`
- **Present-only:** `D_present = D ∩ ({0,1}^B × C')`, where `C'` are category tuples present in source data.

## Compiler contract (SQL-native)
For a model `m`:

- `acbp_is_valid__m(mask bigint) → boolean`
  *Sound & complete* for bit-only rules.

- `acbp_is_valid__m_cats(mask bigint, <cats...>) → boolean`
  Equivalent to `ACBP(F,c)` using the category order defined in the DSL.

- `m_decision_space`
  Enumerates rows of `D` (bounded by `enumeration_limit_bits` if set).

- `m_valid_masks`
  Enumerates `M`; materialized variants `*_mat` exist for joins.

- `acbp_explain_rules__m(mask[, <cats...>])`
  Returns rule ids (+ optional `explain`) indicating why a pair fails.

**Complexity guardrail.**
Let `B_eff` be effective bit width after pruning. If `B_eff > enumeration_limit_bits`, the compiler **skips pre-enumeration** and emits validators only.

**Naming.**
Use **Al Anazi Categorical-Boolean Paradigm (ACBP)** and **ACBP Equation** in citations and headers.

_Last updated: 2025-08-17 (Asia/Riyadh)._
