# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

import argparse, json
from typing import List, Dict, Set

def bitpos_map(flags: List[str]) -> Dict[str, int]:
    return {f:i for i,f in enumerate(flags)}

def scc_equivalence(flags: List[str], constraints: List[dict]) -> List[Set[str]]:
    adj = {f:set() for f in flags}
    implies = {}
    for c in constraints or []:
        t = c["type"].upper()
        if t == "EQUIV":
            a,b = c["a"], c["b"]; adj[a].add(b); adj[b].add(a)
        elif t == "IMPLIES":
            a,b = c["a"], c["b"]; implies.setdefault(a, set()).add(b)

    for a, bs in implies.items():
        for b in bs:
            if b in implies and a in implies[b]:
                adj[a].add(b); adj[b].add(a)

    seen=set(); comps=[]
    for f in flags:
        if f in seen: continue
        stack=[f]; comp=set()
        while stack:
            x=stack.pop()
            if x in seen: continue
            seen.add(x); comp.add(x)
            for y in adj[x]:
                if y not in seen: stack.append(y)
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
    flags       = model["flags"]
    pos         = bitpos_map(flags)
    B           = len(flags)
    limit_bits  = model.get("enumeration_limit_bits", 22)

    if B > limit_bits:
        return []

    def bit(mask, p): return (mask >> p) & 1
    def ok(mask: int) -> bool:
        for c in model.get("constraints", []) or []:
            t = c["type"].upper()
            if t == "IMPLIES":
                a,b = c["a"], c["b"]
                if bit(mask, pos[a]) == 1 and bit(mask, pos[b]) == 0: return False
            elif t == "EQUIV":
                a,b = c["a"], c["b"]
                if bit(mask, pos[a]) != bit(mask, pos[b]): return False
            elif t == "MUTEX":
                a,b = c["a"], c["b"]
                if bit(mask, pos[a]) + bit(mask, pos[b]) > 1: return False
            elif t == "ONEOF":
                fset = c["flags"]
                cnt = sum(bit(mask, pos[f]) for f in fset)
                if cnt != 1: return False
            elif t in ("FORBID_WHEN","FORBID_IF_SQL"):

                continue
        return True

    return [m for m in range(1<<B) if ok(m)]

def _bit_expr(p: int) -> str:
    return f"(((mask >> {p}) & 1))"

def predicate_sql_for_bit_constraints(flags: List[str], constraints: List[dict]) -> str:
    pos = bitpos_map(flags)
    preds=[]
    for c in constraints or []:
        t = c["type"].upper()
        if t == "IMPLIES":
            preds.append(f"({_bit_expr(pos[c['a']])} = 0 OR {_bit_expr(pos[c['b']])} = 1)")
        elif t == "EQUIV":
            preds.append(f"({_bit_expr(pos[c['a']])} = {_bit_expr(pos[c['b']])})")
        elif t == "MUTEX":
            preds.append(f"({_bit_expr(pos[c['a']])} + {_bit_expr(pos[c['b']])} <= 1)")
        elif t == "ONEOF":
            maskbits = sum((1 << pos[f]) for f in c["flags"])
            preds.append(f"(acbp_popcount(mask & {maskbits}) = 1)")
        elif t in ("FORBID_WHEN","FORBID_IF_SQL"):

            pass
    return " AND\n    ".join(preds) if preds else "TRUE"

def _sql_quote(s: str) -> str:
    return s.replace("'", "''")

def generate_categories_cte(categories: Dict[str, List[str]]) -> str:
    if not categories:
        return "cats AS (SELECT 1 AS dummy)"
    parts=[]
    i=1
    for name, vals in categories.items():
        esc = ", ".join("'" + _sql_quote(v) + "'" for v in vals)
        parts.append(f"(SELECT unnest(ARRAY[{esc}]) AS \"{name}\") c{i}")
        i += 1
    return "cats AS (\n  SELECT * FROM " + "\n  CROSS JOIN ".join(parts) + "\n)"

def bit_explain_unions(flags: List[str], constraints: List[dict]) -> str:
    """Return SQL text for UNION ALL of (rule, ok) rows covering bit rules."""
    pos = bitpos_map(flags)
    unions=[]
    for c in constraints or []:
        t = c["type"].upper()
        if t == "IMPLIES":
            a,b=c["a"],c["b"]
            rule = f"IMPLIES({a} -> {b})"
            ok   = f"({_bit_expr(pos[a])} = 0 OR {_bit_expr(pos[b])} = 1)"
        elif t == "EQUIV":
            a,b=c["a"],c["b"]
            rule = f"EQUIV({a} <-> {b})"
            ok   = f"({_bit_expr(pos[a])} = {_bit_expr(pos[b])})"
        elif t == "MUTEX":
            a,b=c["a"],c["b"]
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

def cat_rule_preds(flags: List[str], categories: Dict[str, List[str]], constraints: List[dict]):
    """Return (pred_list, explain_union_list) for category-aware rules."""
    pos = bitpos_map(flags)
    preds=[]
    unions=[]
    for c in constraints or []:
        t = c["type"].upper()
        if t == "FORBID_WHEN":
            flag = c["if_flag"]
            conds = [f"({k} = '{_sql_quote(v)}')" for k,v in c["when"].items()]
            when_sql = " AND ".join(conds) if conds else "TRUE"
            rule = f"FORBID({flag} when " + ", ".join(f"{k}={v}" for k,v in c["when"].items()) + ")"
            ok   = f"NOT ( ({when_sql}) AND ({_bit_expr(pos[flag])} = 1) )"
            preds.append(ok)
            unions.append(f"SELECT '{_sql_quote(rule)}'::text AS rule, ({ok})::boolean AS ok")
        elif t == "FORBID_IF_SQL":
            flag = c["if_flag"]
            condition = c["condition"]
            rule = f"FORBID({flag} when SQL: {condition})"
            ok   = f"NOT ( ({condition}) AND ({_bit_expr(pos[flag])} = 1) )"
            preds.append(ok)
            unions.append(f"SELECT '{_sql_quote(rule)}'::text AS rule, ({ok})::boolean AS ok")

    return preds, unions

def emit_postgres_sql(model: dict) -> str:
    name       = model["name"]
    flags      = model["flags"]
    cats       = model.get("categories", {}) or {}
    cons       = model.get("constraints", []) or []
    B          = len(flags)
    pos        = bitpos_map(flags)
    max_mask   = (1 << B) - 1


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

    bit_pred = predicate_sql_for_bit_constraints(flags, cons)
    valid_masks_view = (
        f"\n-- === Valid masks for {name} (bit-only rules) ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_valid_masks\" AS\n"
        "WITH masks AS (\n"
        f"  SELECT gs::bigint AS mask FROM generate_series(0, {max_mask}) gs\n"
        ")\n"
        "SELECT mask\n"
        "FROM masks\n"
        "WHERE\n"
        f"  {bit_pred}\n"
        ";\n"
    )

    cats_cte = generate_categories_cte(cats)
    cats_view = (
        f"\n-- === Categories for {name} ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_categories\" AS\n"
        f"WITH {cats_cte}\n"
        "SELECT * FROM cats;\n"
    )

    cat_join = f"CROSS JOIN \"{name}_categories\" c" if cats else ""
    decision_space = (
        f"\n-- === Decision space for {name} ===\n"
        f"CREATE OR REPLACE VIEW \"{name}_decision_space\" AS\n"
        f"SELECT m.mask{', c.*' if cats else ''}\n"
        f"FROM \"{name}_valid_masks\" m\n"
        f"{cat_join}\n"
        ";\n"
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
        f"  SELECT ({bit_pred});\n"
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


    cat_preds, cat_unions = cat_rule_preds(flags, cats, cons)
    have_cat_rules = len(cat_preds) > 0


    cat_keys = list(cats.keys())
    cat_sig  = ", ".join(f"{k} text" for k in cat_keys)

    cat_validator = ""
    cat_explainer = ""
    if have_cat_rules:
        all_preds = ["\"acbp_is_valid__%s\"(mask)" % name] + cat_preds
        predicate = " AND ".join(all_preds)
        cat_validator = (
            f"\n-- === Category-aware validator for {name} ===\n"
            f"CREATE OR REPLACE FUNCTION \"acbp_is_valid__{name}_cats\"(mask bigint{', ' if cat_sig else ''}{cat_sig})\n"
            "RETURNS boolean\n"
            "LANGUAGE sql IMMUTABLE STRICT AS $$\n"
            f"  SELECT ({predicate});\n"
            "$$;\n"
        )
        cat_union_sql = "\nUNION ALL\n".join(cat_unions) if cat_unions else ""
        if not cat_union_sql:
            cat_union_sql = "SELECT 'TRUE'::text, TRUE::boolean"
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
        + valid_masks_view
        + cats_view
        + decision_space
        + explain_view
        + validator_fn
        + explain_rules_fn
        + cat_validator
        + cat_explainer
    )

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

    if args.enumerate:
        valid = enumerate_valid_masks(model)
        if valid:
            print(f"  Valid masks enumerated: {len(valid)}")
            print(f"  First few: {valid[:16]}")
        else:
            print(f"  Enumeration skipped (B>{model.get('enumeration_limit_bits', 22)}).")

    sql = emit_postgres_sql(model)
    if args.out_sql:
        with open(args.out_sql, "w", encoding="utf-8") as outf:
            outf.write(sql)
    else:
        print("\n" + sql)

if __name__ == "__main__":
    main()
