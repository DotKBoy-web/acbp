# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK
import argparse, json, os, csv
from typing import List, Dict, Set, Tuple

# ---------- core helpers ----------
def bitpos_map(flags: List[str]) -> Dict[str, int]:
    return {f: i for i, f in enumerate(flags)}

def scc_equivalence(flags: List[str], constraints: List[dict]) -> List[Set[str]]:
    adj = {f: set() for f in flags}
    implies = {}
    for c in constraints or []:
        t = c["type"].upper()
        if t == "EQUIV":
            a, b = c["a"], c["b"]
            adj[a].add(b); adj[b].add(a)
        elif t == "IMPLIES":
            a, b = c["a"], c["b"]
            implies.setdefault(a, set()).add(b)
    for a, bs in implies.items():
        for b in bs:
            if b in implies and a in implies[b]:
                adj[a].add(b); adj[b].add(a)
    seen = set(); comps = []
    for f in flags:
        if f in seen: continue
        stack = [f]; comp = set()
        while stack:
            x = stack.pop()
            if x in seen: continue
            seen.add(x); comp.add(x)
            for y in adj[x]:
                if y not in seen:
                    stack.append(y)
        comps.append(comp)
    return comps

def compute_B_eff(flags: List[str], constraints: List[dict]) -> int:
    return len(scc_equivalence(flags, constraints or []))

def count_category_leaves(categories: Dict[str, List[str]]) -> int:
    if not categories: return 1
    n = 1
    for _, vals in categories.items():
        n *= max(1, len(vals))
    return n

def enumerate_valid_masks(model: dict) -> List[int]:
    flags      = model["flags"]
    pos        = bitpos_map(flags)
    B          = len(flags)
    limit_bits = model.get("enumeration_limit_bits", 22)
    if B > limit_bits:
        return []
    def bit(mask, p): return (mask >> p) & 1
    def ok(mask: int) -> bool:
        for c in model.get("constraints", []) or []:
            t = c["type"].upper()
            if t == "IMPLIES":
                a, b = c["a"], c["b"]
                if bit(mask, pos[a]) == 1 and bit(mask, pos[b]) == 0: return False
            elif t == "EQUIV":
                a, b = c["a"], c["b"]
                if bit(mask, pos[a]) != bit(mask, pos[b]): return False
            elif t == "MUTEX":
                a, b = c["a"], c["b"]
                if bit(mask, pos[a]) + bit(mask, pos[b]) > 1: return False
            elif t == "ONEOF":
                fset = c["flags"]
                cnt = sum(bit(mask, pos[f]) for f in fset)
                if cnt != 1: return False
            elif t in ("FORBID_WHEN", "FORBID_IF_SQL"):
                # category-aware; handled in SQL decision_space
                continue
        return True
    return [m for m in range(1 << B) if ok(m)]

# ---------- SQL builders ----------
def _bit_expr(p: int, mask_expr: str = "mask") -> str:
    return f"((({mask_expr} >> {p}) & 1))"

def predicate_sql_for_bit_constraints(flags: List[str],
                                      constraints: List[dict],
                                      mask_expr: str = "mask") -> str:
    pos = bitpos_map(flags)
    preds = []
    for c in constraints or []:
        t = c["type"].upper()
        if t == "IMPLIES":
            preds.append(f"({_bit_expr(pos[c['a']], mask_expr)} = 0 OR {_bit_expr(pos[c['b']], mask_expr)} = 1)")
        elif t == "EQUIV":
            preds.append(f"({_bit_expr(pos[c['a']], mask_expr)} = {_bit_expr(pos[c['b']], mask_expr)})")
        elif t == "MUTEX":
            preds.append(f"({_bit_expr(pos[c['a']], mask_expr)} + {_bit_expr(pos[c['b']], mask_expr)} <= 1)")
        elif t == "ONEOF":
            maskbits = sum((1 << pos[f]) for f in c["flags"])
            preds.append(f"(acbp_popcount({mask_expr} & {maskbits}) = 1)")
        elif t in ("FORBID_WHEN","FORBID_IF_SQL"):
            pass
    return " AND\n    ".join(preds) if preds else "TRUE"

def _sql_quote(s) -> str:
    return str(s).replace("'", "''")

def _eq_or_in(col: str, spec) -> str:
    if isinstance(spec, (list, tuple)):
        vals = ", ".join("'" + _sql_quote(v) + "'" for v in spec)
        return f"({col} IN ({vals}))"
    else:
        return f"({col} = '{_sql_quote(spec)}')"

def _fmt_when_for_rule(when: dict) -> str:
    parts = []
    for k, v in when.items():
        if isinstance(v, (list, tuple)):
            parts.append(f"{k}={{{'|'.join(map(str, v))}}}")
        else:
            parts.append(f"{k}={v}")
    return ", ".join(parts)

def generate_categories_cte(categories: Dict[str, List[str]]) -> str:
    if not categories:
        return "cats AS (SELECT 1 AS dummy)"
    parts = []
    i = 1
    for name, vals in categories.items():
        esc = ", ".join("'" + _sql_quote(v) + "'" for v in vals)
        parts.append(f"(SELECT unnest(ARRAY[{esc}]) AS \"{name}\") c{i}")
        i += 1
    return "cats AS (\n  SELECT * FROM " + "\n  CROSS JOIN ".join(parts) + "\n)"

def bit_explain_unions(flags: List[str], constraints: List[dict]) -> str:
    pos = bitpos_map(flags)
    unions = []
    for c in constraints or []:
        t = c["type"].upper()
        if t == "IMPLIES":
            a, b = c["a"], c["b"]
            rule = f"IMPLIES({a} -> {b})"
            ok   = f"({_bit_expr(pos[a])} = 0 OR {_bit_expr(pos[b])} = 1)"
        elif t == "EQUIV":
            a, b = c["a"], c["b"]
            rule = f"EQUIV({a} <-> {b})"
            ok   = f"({_bit_expr(pos[a])} = {_bit_expr(pos[b])})"
        elif t == "MUTEX":
            a, b = c["a"], c["b"]
            rule = f"MUTEX({a}, {b})"
            ok   = f"({_bit_expr(pos[a])} + {_bit_expr(pos[b])} <= 1)"
        elif t == "ONEOF":
            fset = c["flags"]
            maskbits = sum((1 << pos[f]) for f in fset)
            rule = f"ONEOF({', '.join(fset)})"
            ok   = f"(acbp_popcount(mask & {maskbits}) = 1)"
        else:
            continue
        unions.append(f"SELECT '{_sql_quote(rule)}'::text AS rule, ({ok})::boolean AS ok")
    if not unions:
        unions.append("SELECT 'TRUE'::text AS rule, TRUE::boolean AS ok")
    return "\nUNION ALL\n".join(unions)

def cat_rule_preds(flags: List[str],
                   categories: Dict[str, List[str]],
                   constraints: List[dict],
                   mask_expr: str = "mask") -> Tuple[List[str], List[str]]:
    pos = bitpos_map(flags)
    preds = []; unions = []
    for c in constraints or []:
        t = c["type"].upper()
        if t == "FORBID_WHEN":
            flag = c["if_flag"]
            when = c.get("when", {})
            conds = [_eq_or_in(k, v) for k, v in when.items()]
            when_sql = " AND ".join(conds) if conds else "TRUE"
            rule_txt = f"FORBID({flag} when " + _fmt_when_for_rule(when) + ")"
            ok   = f"NOT ( ({when_sql}) AND ({_bit_expr(pos[flag], mask_expr)} = 1) )"
            preds.append(ok)
            unions.append(f"SELECT '{_sql_quote(rule_txt)}'::text AS rule, ({ok})::boolean AS ok")
        elif t == "FORBID_IF_SQL":
            flag = c["if_flag"]
            condition = c["condition"]
            rule_txt = f"FORBID({flag} when SQL: {condition})"
            ok   = f"NOT ( ({condition}) AND ({_bit_expr(pos[flag], mask_expr)} = 1) )"
            preds.append(ok)
            unions.append(f"SELECT '{_sql_quote(rule_txt)}'::text AS rule, ({ok})::boolean AS ok")
    return preds, unions

# ---------- sanity estimates ----------
def estimate_sanity(model: dict, valid_masks: List[int]) -> Dict[str, str]:
    flags = model["flags"]
    cats  = model.get("categories", {}) or {}
    cons  = model.get("constraints", []) or []

    v = max(0, len(valid_masks))
    n_eff = count_category_leaves(cats)
    theoretical_max = v * n_eff

    # flag prevalence among bit-only valid masks
    pos = bitpos_map(flags)
    prev = {f: (sum(((m >> pos[f]) & 1) for m in valid_masks) / v) if v > 0 else 0.0
            for f in flags}

    # Combine FORBID_WHEN via 1 - Π(1 - P(flag=1)*P(cat condition))
    forbid_fracs = []
    for c in cons:
        if c.get("type", "").upper() != "FORBID_WHEN": continue
        flag = c["if_flag"]; when = c.get("when", {})
        frac_cats = 1.0
        for col, spec in when.items():
            values = spec if isinstance(spec, list) else [spec]
            denom = max(1, len(cats.get(col, values)))
            frac_cats *= min(1.0, len(values) / denom)
        forbid_fracs.append(prev.get(flag, 0.0) * frac_cats)

    keep_prob = 1.0
    for f in forbid_fracs:
        keep_prob *= (1.0 - max(0.0, min(1.0, f)))
    est_remaining = int(round(theoretical_max * keep_prob))
    est_pruned    = theoretical_max - est_remaining

    prev_line = ", ".join(f"{k}={prev[k]*100:.1f}%" for k in flags)
    notes = []
    fw_count = sum(1 for c in cons if c.get("type", "").upper() == "FORBID_WHEN")
    fisql_count = sum(1 for c in cons if c.get("type", "").upper() == "FORBID_IF_SQL")
    if fw_count:
        pieces = []
        for c in cons:
            if c.get("type", "").upper() != "FORBID_WHEN": continue
            flag = c["if_flag"]; when = c.get("when", {})
            if when:
                col, spec = next(iter(when.items()))
                values = spec if isinstance(spec, list) else [spec]
                denom = max(1, len(cats.get(col, values)))
                pieces.append(f"{flag}@{(len(values)/denom)*100:.2f}%")
        if pieces:
            notes.append("Applied FORBID_WHEN estimates: " + "; ".join(pieces) + ".")
    if fisql_count:
        notes.append(f"Excluded {fisql_count} FORBID_IF_SQL rule(s) from estimate.")

    pct = (est_remaining / theoretical_max * 100) if theoretical_max > 0 else 0.0
    return {
        "prev_line": prev_line,
        "theoretical_max": f"{theoretical_max:,}",
        "est_remaining": f"{est_remaining:,}",
        "est_pruned": f"{est_pruned:,}",
        "est_pct": f"{pct:.1f}%",
        "notes": " ".join(notes) if notes else ""
    }

# ---------- results reader ----------
def _parse_intlike(s: str):
    if s is None: return None
    s = str(s).strip().replace(",", "")
    if s == "": return None
    try:
        if "." in s:
            return int(float(s))
        return int(s)
    except ValueError:
        return None

def latest_summary_metrics(model_name: str):
    base = "papers/results"
    if not os.path.isdir(base): return None
    # expect YYYYMMDDTHHMMSSZ
    candidates = sorted([d for d in os.listdir(base) if len(d) == 16 and d.endswith("Z")])
    for ts in reversed(candidates):
        summ = os.path.join(base, ts, model_name, "summary.csv")
        if os.path.isfile(summ):
            with open(summ, newline="", encoding="utf-8") as f:
                r = csv.DictReader(f)
                row = next(r, None)
                if not row: return None
                return {
                    "ts": ts,
                    "valid_masks": _parse_intlike(row.get("valid_masks")),
                    "decision_rows": _parse_intlike(row.get("decision_rows")),
                    "data_rows": _parse_intlike(row.get("data_rows")),
                    "present_rows": _parse_intlike(row.get("present_rows")),
                }
    return None

# ---------- emitter ----------
def emit_postgres_sql(model: dict) -> str:
    name  = model["name"]
    flags = model["flags"]
    cats  = model.get("categories", {}) or {}
    cons  = model.get("constraints", []) or []
    B     = len(flags)
    pos   = bitpos_map(flags)
    max_mask = (1 << B) - 1

    header = "-- ACBP Postgres SQL for model: {name}\n-- Flags:\n".format(name=name)
    header += "\n".join([f"-- {f:>24s} : bit {pos[f]}" for f in flags]) + "\n"

    helpers = (
        "\n-- === ACBP helpers (idempotent) ===\n"
        "CREATE OR REPLACE FUNCTION acbp_popcount(x bigint)\n"
        "RETURNS int\n"
        "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
        "  SELECT length(replace((x)::bit(64)::text, '0',''));\n"
        "$$;\n"
    )

    # Unqualified (functions)
    bit_pred_unq = predicate_sql_for_bit_constraints(flags, cons, mask_expr="mask")
    cat_preds_unq, cat_unions = cat_rule_preds(flags, cats, cons, mask_expr="mask")
    have_cat_rules = len(cat_preds_unq) > 0

    # Qualified (decision_space WHERE m.mask ...)
    bit_pred_m = predicate_sql_for_bit_constraints(flags, cons, mask_expr="m.mask")
    cat_preds_m, _ = cat_rule_preds(flags, cats, cons, mask_expr="m.mask")
    full_pred_m = f"({bit_pred_m})" if not cat_preds_m else f"({bit_pred_m}) AND (\n    " + " AND\n    ".join(cat_preds_m) + "\n  )"

    cats_cte = generate_categories_cte(cats)
    cats_view = (
        f"\n-- === Categories for {name} ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_categories\" AS\n"
        f"WITH {cats_cte}\n"
        "SELECT * FROM cats;\n"
    )

    decision_space = (
        f"\n-- === Decision space for {name} (PRUNED by bit + category rules) ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_decision_space\" AS\n"
        f"WITH masks AS (\n"
        f"  SELECT gs::bigint AS mask FROM generate_series(0, {max_mask}) gs\n"
        f"),\n"
        f"{cats_cte}\n"
        f"SELECT m.mask{', c.*' if cats else ''}\n"
        f"FROM masks m\n"
        f"{'CROSS JOIN cats c' if cats else ''}\n"
        f"WHERE\n"
        f"  {full_pred_m}\n"
        f";\n"
    )

    valid_masks_view = (
        f"\n-- === Valid masks for {name} (derived from PRUNED decision space) ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_valid_masks\" AS\n"
        f"SELECT DISTINCT mask FROM \"{name}_decision_space\";\n"
    )

    bitcols = ",\n  ".join([f"({_bit_expr(pos[f])}) AS \"{f}\"" for f in flags])
    explain_view = (
        f"\n-- === Bit-explained view for {name} ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_explain\" AS\n"
        "SELECT\n"
        "  mask,\n"
        f"  {bitcols}\n"
        f"FROM \"{name}_valid_masks\";\n"
    )

    validator_fn = (
        f"\n-- === Validator (bit-only) for {name} ===\n"
        f"CREATE OR REPLACE FUNCTION \"acbp_is_valid__{name}\"(mask bigint)\n"
        "RETURNS boolean\n"
        "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
        f"  SELECT ({bit_pred_unq});\n"
        "$$;\n"
    )

    bit_unions_sql = bit_explain_unions(flags, cons)
    explain_rules_fn = (
        f"\n-- === Bit-only explainer for {name} ===\n"
        f"CREATE OR REPLACE FUNCTION \"acbp_explain_rules__{name}\"(mask bigint)\n"
        "RETURNS TABLE(rule text, ok boolean)\n"
        "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
        f"{bit_unions_sql}\n"
        "$$;\n"
    )

    cat_keys = list(cats.keys())
    cat_sig  = ", ".join(f"{k} text" for k in cat_keys)
    cat_validator = ""
    cat_explainer = ""
    if have_cat_rules:
        predicate_unq = " AND ".join([bit_pred_unq] + cat_preds_unq)
        cat_validator = (
            f"\n-- === Category-aware validator for {name} ===\n"
            f"CREATE OR REPLACE FUNCTION \"acbp_is_valid__{name}_cats\"(mask bigint{', ' if cat_sig else ''}{cat_sig})\n"
            "RETURNS boolean\n"
            "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
            f"  SELECT ({predicate_unq});\n"
            "$$;\n"
        )
        cat_union_sql = "\nUNION ALL\n".join(cat_unions) if cat_unions else "SELECT 'TRUE'::text, TRUE::boolean"
        cat_explainer = (
            f"\n-- === Category-aware explainer for {name} ===\n"
            f"CREATE OR REPLACE FUNCTION \"acbp_explain__{name}\"(mask bigint{', ' if cat_sig else ''}{cat_sig})\n"
            "RETURNS TABLE(rule text, ok boolean)\n"
            "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
            "WITH bit_rules AS (\n"
            f"{bit_unions_sql}\n"
            "), cat_rules AS (\n"
            f"{cat_union_sql}\n"
            ")\n"
            "SELECT * FROM bit_rules\n"
            "UNION ALL\n"
            "SELECT * FROM cat_rules;\n"
            "$$;\n"
        )

    return (
        header
        + helpers
        + cats_view
        + decision_space
        + valid_masks_view
        + explain_view
        + validator_fn
        + explain_rules_fn
        + cat_validator
        + cat_explainer
    )

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser(description="ACBP JSON tester & SQL emitter (adoptable)")
    ap.add_argument("model_json", help="Path to JSON model file")
    ap.add_argument("-o", "--out-sql", help="Write generated SQL to this file")
    ap.add_argument("--enumerate", action="store_true", help="Enumerate valid masks if feasible (bit-only)")
    args = ap.parse_args()

    with open(args.model_json, "r", encoding="utf-8") as f:
        model = json.load(f)

    flags = model["flags"]
    cons  = model.get("constraints", []) or []
    cats  = model.get("categories", {}) or {}
    B     = len(flags)
    B_eff = compute_B_eff(flags, cons)
    n_eff = count_category_leaves(cats)

    print(f"Model: {model['name']}")
    print(f"  B (flags):       {B}")
    print(f"  B_eff (reduced): {B_eff}")
    print(f"  n_eff (cats):    {n_eff}")
    print(f"  Complexity:      2^{B_eff} * {n_eff}")

    valid = []
    if args.enumerate:
        valid = enumerate_valid_masks(model)
        if valid:
            print(f"  Valid masks enumerated (bit-only): {len(valid)} / {1<<B}")
            print(f"  First few: {valid[:16]}")
        else:
            print(f"  Enumeration skipped (B>{model.get('enumeration_limit_bits', 22)}).")

    if args.enumerate and valid:
        est = estimate_sanity(model, valid)
        print("\n=== Sanity estimates (uniform, independent categories; FORBID_WHEN only) ===")
        print(f"  Flag prevalence among valid masks: {est['prev_line']}")
        print(f"  Theoretical max rows (bit-only):   {est['theoretical_max']}")
        print(f"  Est. remaining rows (cat rules):   {est['est_remaining']}  (~{est['est_pct']} of max)")
        print(f"  Est. pruned rows (cat rules):      {est['est_pruned']}")
        if est["notes"]:
            print(f"  note: {est['notes']}")

        # If we have a recent summary.csv, show actuals side-by-side
        sm = latest_summary_metrics(model["name"])
        if sm and sm.get("decision_rows") is not None:
            theoretical_max = int(est["theoretical_max"].replace(",", ""))
            actual = sm["decision_rows"]
            pct = (actual / theoretical_max * 100.0) if theoretical_max > 0 else 0.0
            pruned = theoretical_max - actual
            print("\n=== Actuals (latest summary) ===")
            print(f"  Decision rows: {actual:,}  (~{pct:.1f}% of theoretical; pruned {pruned:,})")
            if sm.get("present_rows") is not None:
                print(f"  Present-only rows: {sm['present_rows']:,}")
            if sm.get("data_rows") is not None:
                print(f"  Data rows: {sm['data_rows']:,}")
            print(f"  Source: papers/results/{sm['ts']}/{model['name']}/summary.csv")

    sql = emit_postgres_sql(model)
    if args.out_sql:
        with open(args.out_sql, "w", encoding="utf-8") as outf:
            outf.write(sql)
    else:
        print("\n" + sql)

if __name__ == "__main__":
    main()
