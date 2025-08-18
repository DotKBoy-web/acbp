
> See also: **[The ACBP Equation](docs/ACBP-Equation.md)** — canonical definition & compiler contract.

# ACBP DSL (Domain-Specific Language) — Specification

## Goals
- Declaratively define **bit flags** (“B” dimension) and **categorical dimensions**,
- Encode **validity rules** on bits and categories,
- Generate portable SQL artifacts:
  - `<model>_valid_masks` view
  - `<model>_decision_space` view
  - `acbp_is_valid__<model>(mask)` (bit-only)
  - `acbp_is_valid__<model>_cats(...)` (bit+category)
  - `acbp_explain_rules__<model>(mask)` (bit-only explain)

The compiler (`acbp_tester.py`) takes a JSON file and emits SQL. The DB helper
functions in `acbp.sh install-db-utils` add materialization, refresh and bench helpers.

---

## Core concepts

### Bit flags
A fixed-width set of boolean switches. Each flag has a **name** and an **index** (bit position).
Masks are stored as `bigint` and validated by `acbp_is_valid__<model>(mask)`.

### Categories
Named categorical dimensions with a finite set of allowed **values** (strings).
The decision space is the (constrained) Cartesian product of category values.

### Rules
Rules prune invalid combinations. Two classes:
- **Bit rules**: depend only on bit flags (mask).
- **Category rules**: depend on categories (optionally conditioned on bits).

## File format (overview)

```json
{
  "model": "clinic_visit",
  "bits": [
    { "name": "elective_hours", "index": 0, "doc": "Elective schedule only" },
    { "name": "urgent_slot",    "index": 1 },
    { "name": "virtual_ok",     "index": 2 },
    { "name": "peds_only",      "index": 3 },
    { "name": "attending_only", "index": 4 }
  ],
  "categories": [
    { "name": "appt_type",    "values": ["NewPatient","FollowUp","Procedure","Teleconsult"] },
    { "name": "site",         "values": ["Main","Annex","Downtown"] },
    { "name": "age_group",    "values": ["Peds","Adult"] },
    { "name": "department",   "values": ["General","Pediatrics","Cardiology","Imaging","Orthopedics"] },
    { "name": "provider_role","values": ["Attending","Resident","NP/PA"] },
    { "name": "modality",     "values": ["InPerson","Virtual"] },
    { "name": "visit_hour",   "values": ["08:00","09:00","10:00","11:00","12:00","14:00","16:00","18:00"] },
    { "name": "weekday",      "values": ["Mon","Tue","Wed","Thu","Fri"] },
    { "name": "insurance",    "values": ["Private","Government","SelfPay"] }
  ],
  "rules": {
    "bit_rules": [
      { "forbid_when": ["peds_only"], "expr": { "age_group": { "neq": "Peds" } }, "doc": "Peds bit forbids non-peds" }
    ],
    "cat_rules": [
      { "expr": { "modality": { "eq": "Virtual" }, "provider_role": { "neq": "Attending" } },
        "doc": "Virtual must be attended by Attending" }
    ],
    "implies": [
      { "when_bits": ["attending_only"], "require": { "provider_role": { "eq": "Attending" } } }
    ],
    "mutex_bits": [
      ["elective_hours","urgent_slot"]
    ]
  }
}
```

## Semantics (normative)

### Evaluation model

- A mask is a `bigint`. Bit i is set iff `(mask >> i) & 1 = 1`.
- The `decision space` is the (constrained) Cartesian product of category values in the JSON order.
- A combination is `valid` iff all rules pass.
- Compiler prints `B`, `B_eff`, `n_eff`, and `Complexity = 2^B_eff * n_eff`.

### Rule truth tables
```t
    | In all forms below, the predicate `P(cats)` is evaluated against the category tuple.
```
* `bit_rules[]` (forbid when bits are set):
If all `forbid_when` bits are 1 and `P(cats)` is true ⇒ forbid.
SQL shape:
```sql
    NOT ( (bit_and(mask, SUM(1<<idx_for_each_forbid_bit)) = SUM(1<<idx...)) AND (P_sql) )
```
* `cat_rules[]` (bit-agnostic forbids):
If `P(cats)` is true ⇒ forbid.
SQL shape:
```sql
    NOT (P_sql)
```
* `implies[]` (bits ⇒ required predicate):
If all `when_bits` are 1 ⇒ `P(cats)` must be true.
SQL shape (logically equivalent to the above):
```sql
(bit_and(mask, SUM(...)) <> SUM(...)) OR (P_sql)
```
* `mutex_bits[]`: any pair listed cannot be simultaneously 1.
SQL shape:
```sql
NOT ( ((mask >> i) & 1) = 1 AND ((mask >> j) & 1) = 1 )
```
### Predicate → SQL mapping

Assume column `col` is a text enum.
```c
| JSON predicate   	            | SQL fragment
| { "col": {"eq":"A"} }	        | col = 'A'
| { "col": {"neq":"A"} }	    | col <> 'A'
| { "col": {"in":["A","B"]} }	| col IN ('A','B')
| { "col": {"nin":["X","Y"]} }  | col NOT IN ('X','Y')
| { "all":[ P1, P2, ... ] }	    | (P1_sql) AND (P2_sql) AND ...
| { "any":[ P1, P2, ... ] }	    | (P1_sql) OR (P2_sql) OR ...
| { "not": P }	                | NOT (P_sql)
```
```t
    | Multiple keys in a single object level are AND’ed:
        { "modality":{"eq":"Virtual"}, "provider_role":{"eq":"Attending"} } ⇒ modality='Virtual' AND provider_role='Attending'.
```

### Category column order (guarantee)

* The columns of `<model>_decision_space` appear as:
```css
mask, <categories[0].name>, <categories[1].name>, ...
```
* This order is used for the composite unique index in the materialized view.

## Identifier & value rules

* Bit names and category names: `^[A-Za-z_][A-Za-z0-9_]*$` (recommended).
They become SQL identifiers; the compiler will quote as needed, but sticking to this avoids surprises.
* Category values are strings; they’re emitted as single-quoted SQL literals. Avoid embedded ' where possible.
* Values are case-sensitive.

## Generated artifacts (names are stable)

### Given `model = "X"`:

* Views:
    * X_valid_masks
    * X_decision_space

* Functions:
    * acbp_is_valid__X(mask bigint) returns boolean
    * acbp_is_valid__X_cats(mask bigint, <cats...>) returns boolean
    * acbp_explain_rules__X(mask bigint) returns table(rule text, ok boolean)

* Optional helper artifacts (from acbp.sh install-db-utils):
    * Materialized: X_valid_masks_mat, X_decision_space_mat, X_present_mat
    * Helpers: acbp_materialize(text[, force bool]), acbp_refresh(text)
    * Present-only: acbp_materialize_present(text model, text data_table), acbp_refresh_present(text)
    * Bench: acbp_bench_valid_join, acbp_bench_valid_func, acbp_bench_full_join, acbp_bench_full_join_present
    * Index helper: acbp_create_matching_index(text model, text data_table)

## Versioning & metadata

Add optional top-level fields (forward-compatible):
```json
{
  "acbp_version": 1,
  "model": "clinic_visit",
  "meta": {
    "title": "Outpatient clinic visit",
    "owner": "DotK",
    "updated": "2025-08-16"
  },
  ...
}
```
The compiler currently treats unknown keys as no-ops; they’re retained for provenance.

## Examples

1) Forbid: “Virtual must be Attending”
```json
{ "expr": { "modality": {"eq":"Virtual"}, "provider_role": {"neq":"Attending"} } }
```
This is a cat_rule (forbid). Any tuple matching that predicate is excluded.

2) Imply: “If attending_only bit is set ⇒ provider_role=Attending”
```json
{ "when_bits": ["attending_only"], "require": { "provider_role": {"eq":"Attending"} } }
```
3) Mutex: elective vs urgent
```json
["elective_hours","urgent_slot"]
```

## Complexity notes

* `B_eff` is the size of the independent bit space after static reductions (e.g., mutex).
* `n_eff` is the size of the category product after pruning by static category rules known at compile time (if the compiler performs such reductions). Runtime `valid_masks`/`decision_space` views apply the full set of rules.
* The console printout during compile (`B`, `B_eff`, `n_eff`, `Complexity`) is a quick sanity check on model breadth.

## Best practices

* Keep bits policy-like (capabilities/toggles), and keep categories data-like.
* Prefer `implies` (allowing both sides) when expressing “if bit => must have X”.
Use `bit_rules` when listing forbidden combinations under a bit.
* Group broader constraints under `cat_rules` (bit-agnostic forbids).
* Order categories by the way you plan to group; it impacts the composite index order and grouping performance.
* For speed on big tables, run:
    * `acbp_create_matching_index(model, data_table)`
    * `VACUUM ANALYZE data_table`
    * Use `*_present_mat` for present-only decision spaces tied to your data.

## Validation

A JSON Schema is provided at docs/acbp.schema.json. Quick check:
```bash
python - <<'PY'
import json, jsonschema
schema=json.load(open('docs/acbp.schema.json'))
doc=json.load(open('clinic_visit.json'))
jsonschema.validate(doc, schema)
print('OK')
PY
```

## Known limitations

* Only discrete string categories are supported (no numeric ranges yet).
* Predicates are conjunctions/disjunctions over equality/membership; regex/range comparisons are out of scope for v1.
* The compiler emits PostgreSQL-flavored SQL; other dialects may need light tweaks (quoting, functions).

## Changelog

v1: initial JSON DSL with `bits`, `categories`, `bit_rules`, `cat_rules`, `implies`, `mutex_bits`.

## Copyright & License

<!-- SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0 -->
<!-- Copyright (c) 2025 DotK (Muteb Hail S Al Anazi) -->
(see `LICENSE`).
Third-party licenses in `THIRD_PARTY_NOTICES.md`.

## How to cite

    | DotK (Muteb Hail S Al Anazi) (2025). ACBP: A Bit-&-Category Policy DSL for Structured Decision Spaces. Version v1. Git tag: v0.1.1.
