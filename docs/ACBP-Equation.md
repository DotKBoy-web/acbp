# The ACBP Equation (canonical)
_Last updated: 2025-08-18 (Asia/Riyadh)_

**Objects.**
- Flags: $F \in \{0,1\}^B$ (ordered bitmask over boolean state).
- Categories: $c \in C = \prod_i C_i$ (finite, typed dimensions).
- Rules: $R$ (each rule is a predicate $r(F,c)$).

**Definition (validity).**
$$
\mathrm{ACBP}(F,c) \;:=\; \bigwedge_{r \in R} r(F,c)
$$

**Sets.**
- **Valid masks:** $M \;=\; \{\, F \mid \exists c \in C : \mathrm{ACBP}(F,c) \,\}$
- **Decision space:** $D \;=\; \{\, (F,c) \in \{0,1\}^B \times C \mid \mathrm{ACBP}(F,c) \,\}$
- **Present-only:** $D_{\text{present}} \;=\; D \cap (\{0,1\}^B \times C')$ where $C'$ are category tuples present in source data.

**Strict binding (current release).**
$$
M \;=\; \pi_F(D) \qquad\text{(i.e., $M$ is the projection of $D$ over flags)}
$$

---

## Compiler contract (SQL-native)

For a model $m$:

- `acbp_is_valid__m(mask bigint) → boolean`
  _Sound & complete_ for bit-only rules.

- `acbp_is_valid__m_cats(mask bigint, <cats...>) → boolean`
  Equivalent to $\mathrm{ACBP}(F,c)$ using the category order defined in the DSL.

- `m_decision_space`
  Enumerates rows of $D$ (bounded by `enumeration_limit_bits` if set).

- `m_valid_masks`
  Enumerates $M$; materialized variants `*_mat` exist for joins. In strict mode:
  $$
  m\_\text{valid\_masks\_mat} \;=\; \pi_F\!\big(m\_\text{decision\_space\_mat}\big)
  $$

- `acbp_explain_rules__m(mask[, <cats...>])`
  Returns rule ids (+ optional `explain`) indicating why a pair fails.

---

## Complexity guardrail

Let $B_{\text{eff}}$ be effective bit width after static pruning.
If $B_{\text{eff}} > \texttt{enumeration\_limit\_bits}$, the compiler **skips pre-enumeration** and emits validators only.

---

## Naming

Use **Al Anazi Categorical-Boolean Paradigm (ACBP)** and **ACBP Equation** in citations and headers.
