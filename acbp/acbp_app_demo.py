# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

import json, os, time, glob, shutil, subprocess
from typing import Dict, Optional, List
import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

st.set_page_config(page_title="ACBP Bench & Explorer (Demo)", layout="wide")
st.title("ACBP Bench & Explorer — DSL + Bench Demo")

# --------------------------- utils ---------------------------
def mask_dsn(dsn: str) -> str:
    try:
        p, r = dsn.split("://", 1)
        if "@" in r and ":" in r.split("@", 1)[0]:
            creds, tail = r.split("@", 1)
            user, _ = creds.split(":", 1)
            return f"{p}://{user}:******@{tail}"
    except Exception:
        pass
    return dsn

def _to_mapping(x):
    if isinstance(x, dict): return x
    if x is None: return {}
    if isinstance(x, (bytes, bytearray)):
        try: x = x.decode("utf-8", errors="ignore")
        except Exception: return {}
    if isinstance(x, str):
        try: return json.loads(x)
        except Exception: return {}
    return {}

@st.cache_resource(show_spinner=False)
def get_engine(dsn: str) -> Engine:
    return create_engine(dsn, pool_pre_ping=True)

def run_df(engine: Engine, sql: str, params: Optional[Dict]=None) -> pd.DataFrame:
    with engine.connect() as c:
        return pd.read_sql_query(text(sql), c, params=params or {})

def run_scalar(engine: Engine, sql: str, params: Optional[Dict]=None):
    with engine.connect() as c:
        row = c.execute(text(sql), params or {}).fetchone()
        return list(row)[0] if row is not None else None

def list_models(engine: Engine) -> List[str]:
    sql = """
      SELECT REPLACE(table_name, '_decision_space','') AS model
      FROM information_schema.views
      WHERE table_schema='public' AND table_name LIKE '%\\_decision_space' ESCAPE '\\'
      ORDER BY 1;
    """
    df = run_df(engine, sql)
    return df["model"].tolist()

def function_exists(engine: Engine, fn_name: str) -> bool:
    sql = """
      SELECT 1
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname=:name
      LIMIT 1;
    """
    return run_df(engine, sql, {"name": fn_name}).shape[0] > 0

# --------------------------- connection ---------------------------
st.sidebar.header("Connection")
host = st.sidebar.text_input("Host", "127.0.0.1")
port = st.sidebar.number_input("Port", 5434, step=1)
user = st.sidebar.text_input("User", "postgres")
password = st.sidebar.text_input("Password", "acbp", type="password")
database = st.sidebar.text_input("Database", "postgres")
dsn = f"postgresql+psycopg2://{user}:{password}@{host}:{int(port)}/{database}"
st.sidebar.caption("Resolved DSN (masked):")
st.sidebar.code(mask_dsn(dsn))
connect = st.sidebar.button("Connect / Reconnect", type="primary")

engine = st.session_state.get("engine")
if connect or engine is None or st.session_state.get("dsn") != dsn:
    try:
        engine = get_engine(dsn)
        info = run_df(
            engine,
            "SELECT current_user, inet_server_addr() AS server_ip, inet_client_addr() AS client_ip, "
            "       setting AS password_encryption "
            "FROM pg_settings WHERE name='password_encryption';"
        )
        st.session_state["engine"] = engine
        st.session_state["dsn"] = dsn
        st.sidebar.success(
            f"Connected as {info.loc[0,'current_user']} "
            f"@ {info.loc[0,'server_ip']} (client={info.loc[0,'client_ip']}) "
            f"[pw={info.loc[0,'password_encryption']}]"
        )
    except Exception as e:
        st.sidebar.error("Connection failed.")
        st.sidebar.code(str(e))
        st.stop()

# --------------------------- pick model + data ---------------------------
models = list_models(engine)
if not models:
    st.warning("No models found (no *_decision_space views). Compile/apply JSON first.")
    st.stop()

c_mod, c_tbl, c_var, c_top = st.columns([1,1,1,1])
with c_mod:
    model = st.selectbox("Model", models, index=0)
with c_tbl:
    data_table = st.text_input("Data table", value=f"{model}_data")
with c_var:
    variant = st.radio("Variant", ["Full decision space", "Present-only"], index=0, horizontal=True)
with c_top:
    top_n = st.number_input("Top N", value=12, min_value=1, step=1)

st.divider()

# =========================== DSL viewer ===========================
st.subheader("DSL (JSON) overview")

# find a reasonable JSON source (same name if present)
guesses = [f"{model}.json"] + sorted(glob.glob("*.json"))
json_text, json_path = "", None
for p in guesses:
    if os.path.exists(p):
        try:
            json_text = open(p, "r", encoding="utf-8").read()
            json_path = p
            break
        except Exception:
            pass

colL, colR = st.columns([1,1])
with colL:
    st.caption(f"Showing: {json_path or '(no local JSON found — place {model}.json next to the app)'}")
    st.code(json_text[:4000] if json_text else "(no JSON available)")

# parse DSL to extract flags/cats if possible
flags, cats = [], {}
try:
    if json_text:
        j = json.loads(json_text)
        flags = j.get("flags") or j.get("bits") or []
        cats  = j.get("categories") or j.get("cats") or {}
except Exception:
    pass

with colR:
    met1, met2, met3, met4 = st.columns(4)
    # DB-derived counts
    decision_rows = run_scalar(engine, f'SELECT COUNT(*) FROM "{model}_decision_space";') or 0
    valid_masks   = run_scalar(engine, f'SELECT COUNT(*) FROM "{model}_valid_masks";') or 0
    # approximate B from JSON (preferred); else leave blank
    B = len(flags) if isinstance(flags, list) else (flags.get("count") if isinstance(flags, dict) else None)
    complexity = f"2^{B} × {decision_rows:,}" if B is not None else f"(set size) {decision_rows:,}"
    met1.metric("Flags (B)", "-" if B is None else f"{B}")
    met2.metric("Decision space rows (nₑff)", f"{decision_rows:,}")
    met3.metric("Valid masks enumerated", f"{valid_masks:,}")
    met4.metric("Complexity", complexity)

    # flags table
    if isinstance(flags, list) and flags:
        st.caption("Flags")
        st.dataframe(pd.DataFrame(flags), use_container_width=True, hide_index=True)
    # categories table
    if isinstance(cats, dict) and cats:
        rows = [{"category": k, "values": len(v) if isinstance(v, list) else None} for k, v in cats.items()]
        st.caption("Categories")
        st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)

st.divider()

# =========================== Benchmarks ===========================
st.subheader("Benchmarks")

b1, b2, b3 = st.columns([1,1,2])
with b1:
    do_run = st.button("Run (count + top groupings)", type="primary")
with b2:
    st.caption("Measures wall-clock in client. For deeper detail, use EXPLAIN ANALYZE in the SQL tab.")
with b3:
    pass

if do_run:
    # valid via JOIN
    t0 = time.perf_counter()
    try:
        vj = run_scalar(engine, "SELECT acbp_bench_valid_join(:m,:t,true);", {"m": model, "t": data_table})
        t_vj = time.perf_counter() - t0
    except Exception as e:
        vj, t_vj = None, None
        st.error("valid_join failed."); st.exception(e)

    # valid via function
    t1 = time.perf_counter()
    try:
        vf = run_scalar(engine, "SELECT acbp_bench_valid_func(:m,:t);", {"m": model, "t": data_table})
        t_vf = time.perf_counter() - t1
    except Exception as e:
        vf, t_vf = None, None
        st.error("valid_func failed."); st.exception(e)

    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Valid via JOIN", f"{vj:,}" if vj is not None else "—", f"{t_vj:.3f}s" if t_vj else None)
    m2.metric("Valid via function", f"{vf:,}" if vf is not None else "—", f"{t_vf:.3f}s" if t_vf else None)

    # top groups
    st.subheader("Top groupings")
    t2 = time.perf_counter()
    try:
        if variant == "Full decision space":
            groups = run_df(
                engine, "SELECT * FROM acbp_bench_full_join(:m,:t,true,:n);",
                {"m": model, "t": data_table, "n": int(top_n)}
            )
        else:
            if function_exists(engine, "acbp_bench_full_join_present"):
                groups = run_df(
                    engine, "SELECT * FROM acbp_bench_full_join_present(:m,:t,:n);",
                    {"m": model, "t": data_table, "n": int(top_n)}
                )
            else:
                st.warning("present-only helper not installed; falling back to full.")
                groups = run_df(
                    engine, "SELECT * FROM acbp_bench_full_join(:m,:t,true,:n);",
                    {"m": model, "t": data_table, "n": int(top_n)}
                )
        t_grp = time.perf_counter() - t2

        gL, gR = st.columns([3,1])
        with gL:
            if not groups.empty and "group_obj" in groups.columns:
                expanded = pd.json_normalize(groups["group_obj"].apply(_to_mapping))
                show = pd.concat([expanded, groups[["visits"]]], axis=1)
                st.dataframe(show, use_container_width=True, height=480)
                st.caption(f"Grouping query time: {t_grp:.3f}s")
                st.download_button("Download CSV", show.to_csv(index=False).encode("utf-8"),
                                   file_name=f"{model}_top_groups.csv", mime="text/csv")
            else:
                st.dataframe(groups, use_container_width=True, height=480)
                st.caption(f"Grouping query time: {t_grp:.3f}s")
        with gR:
            if "visits" in groups.columns:
                st.bar_chart(groups["visits"])
    except Exception as e:
        st.error("Grouping query failed."); st.exception(e)

st.divider()

# =========================== Explain (bit-only) ===========================
st.subheader("Explain mask (bit-only rules)")
cE1, cE2 = st.columns([1,3])
with cE1:
    mask_val = st.number_input("Mask", min_value=0, value=7, step=1)
    do_explain = st.button("Explain")
with cE2:
    st.caption(f'Uses function: "acbp_explain_rules__{model}"')

if do_explain:
    sql = f'SELECT * FROM "acbp_explain_rules__{model}"(:mask) WHERE NOT ok;'
    try:
        df = run_df(engine, sql, {"mask": int(mask_val)})
        if df.empty:
            st.success("Mask satisfies all bit-only rules.")
        else:
            st.dataframe(df, use_container_width=True)
    except Exception as e:
        st.error("Explain failed."); st.exception(e)

st.divider()

# =========================== SQL pad (optional) ===========================
with st.expander("SQL (optional: timing / EXPLAIN)"):
    sql_text = st.text_area("SQL", value=f"EXPLAIN ANALYZE SELECT * FROM {model}_decision_space LIMIT 100;")
    if st.button("Run SQL"):
        try:
            df = run_df(engine, sql_text)
            st.dataframe(df, use_container_width=True, height=450)
        except Exception as e:
            st.error("Query failed."); st.exception(e)
